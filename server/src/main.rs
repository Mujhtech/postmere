use postmere_core::{AppState, auth, config::Config, db};
use postmere_mail::{mail, mail_sync};
use postmere_server::{application, feature_routes};
use sqlx::postgres::PgPoolOptions;
use std::{
    io::{IsTerminal, Read},
    sync::Arc,
};
use uuid::Uuid;
use zeroize::Zeroizing;

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| {
                concat!(
                    "postmere_server=info,postmere_core=info,postmere_providers=info,",
                    "postmere_mail=info,postmere_tracking=info,postmere_calendar=info,",
                    "postmere_collaboration=info,postmere_ai=info,postmere_unsubscribe=info,",
                    "postmere_mcp=info,postmere_mcp_auth=info,postmere_mcp_operations=info,",
                    "postmere_realtime=info,postmere_push=info,postmere_webhooks=info"
                )
                .into()
            }),
        )
        .init();
    if let Err(error) = run().await {
        eprintln!("Postmere server failed: {error}");
        std::process::exit(1);
    }
}
async fn run() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<String> = std::env::args().collect();
    let config = Config::from_env()?;
    match args.get(1).map(String::as_str).unwrap_or("serve") {
        "migrate" => {
            // Migration credentials may be separate from the runtime role.
            let pool = PgPoolOptions::new()
                .max_connections(1)
                .connect(&config.database_url)
                .await
                .map_err(|_| "database connection failed")?;
            db::migrate(&pool).await?;
            println!("Database migrations applied.");
        }
        "bootstrap" => {
            let email = args
                .get(2)
                .ok_or(
                    "Usage: postmere-server bootstrap <email> <workspace-name> (password on stdin)",
                )?
                .trim()
                .to_lowercase();
            let name = args.get(3).ok_or("Workspace name is required")?.trim();
            if email.len() > 254
                || !email.contains('@')
                || email.bytes().any(|b| b.is_ascii_control())
                || name.is_empty()
                || name.len() > 120
            {
                return Err("Invalid email or workspace name".into());
            }
            if std::io::stdin().is_terminal() {
                return Err("Pipe the password from a password manager or a protected file; interactive plaintext entry is disabled".into());
            }
            let mut password = Zeroizing::new(String::new());
            std::io::stdin().take(1026).read_to_string(&mut password)?;
            while password.ends_with(['\n', '\r']) {
                password.pop();
            }
            if !(12..=1024).contains(&password.len()) {
                return Err("Password must contain 12–1024 bytes".into());
            }
            let hash = auth::hash_password(password).await?;
            let pool = db::connect(&config.database_url).await?;
            let mut tx = pool.begin().await?;
            let user_id = Uuid::new_v4();
            let workspace_id = Uuid::new_v4();
            sqlx::query("INSERT INTO users (id,email,password_hash) VALUES ($1,$2,$3)")
                .bind(user_id)
                .bind(&email)
                .bind(hash)
                .execute(&mut *tx)
                .await
                .map_err(|_| "Could not create user; email may already exist")?;
            sqlx::query("INSERT INTO workspaces (id,name) VALUES ($1,$2)")
                .bind(workspace_id)
                .bind(name)
                .execute(&mut *tx)
                .await?;
            sqlx::query(
                "INSERT INTO memberships (workspace_id,user_id,role) VALUES ($1,$2,'owner')",
            )
            .bind(workspace_id)
            .bind(user_id)
            .execute(&mut *tx)
            .await?;
            tx.commit().await?;
            println!("Created owner {email}\nUser: {user_id}\nWorkspace: {workspace_id}");
        }
        "serve" => {
            let pool = db::connect(&config.database_url).await?;
            let addr = config.bind_addr;
            let state = AppState::new(pool, config).await?;
            let push = Arc::new(postmere_push::PushService::from_env()?);
            let webhooks = Arc::new(postmere_webhooks::WebhookService::from_env(&state)?);
            let listener = tokio::net::TcpListener::bind(addr).await?;
            let worker = mail::spawn_delivery_worker(state.clone());
            let sync_worker = mail_sync::spawn_sync_worker(state.clone());
            let triage_worker = postmere_ai::spawn_triage_worker(state.clone());
            let webhook_worker = postmere_webhooks::spawn_worker(state.clone(), webhooks.clone());
            let push_worker = if push.configured() {
                postmere_push::spawn_live_activity_worker(state.clone(), push.clone());
                Some(postmere_push::spawn_worker(state.clone(), push.clone()))
            } else {
                tracing::info!(
                    event = "push_disabled",
                    "Remote push notifications are disabled"
                );
                None
            };
            let (shutdown_sender, shutdown_signal) = postmere_realtime::shutdown_channel();
            let app = application(state, feature_routes())
                .layer(axum::Extension(push))
                .layer(axum::Extension(webhooks))
                .layer(axum::Extension(shutdown_signal));
            tracing::info!(%addr, "Postmere API listening");
            let result = axum::serve(
                listener,
                app.into_make_service_with_connect_info::<std::net::SocketAddr>(),
            )
            .with_graceful_shutdown(async move {
                shutdown().await;
                let _ = shutdown_sender.send(true);
            })
            .await;
            worker.abort();
            sync_worker.abort();
            triage_worker.abort();
            webhook_worker.abort();
            if let Some(push_worker) = push_worker {
                push_worker.abort();
                let _ = push_worker.await;
            }
            let _ = worker.await;
            let _ = sync_worker.await;
            let _ = triage_worker.await;
            let _ = webhook_worker.await;
            result?;
        }
        _ => {
            return Err(
                "Usage: postmere-server [serve|migrate|bootstrap <email> <workspace-name>]".into(),
            );
        }
    }
    Ok(())
}
async fn shutdown() {
    let ctrl_c = async {
        let _ = tokio::signal::ctrl_c().await;
    };
    #[cfg(unix)]
    let terminate = async {
        if let Ok(mut signal) =
            tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
        {
            signal.recv().await;
        } else {
            std::future::pending::<()>().await;
        }
    };
    #[cfg(not(unix))]
    let terminate = std::future::pending::<()>();
    tokio::select! { _ = ctrl_c => {}, _ = terminate => {} }
}
