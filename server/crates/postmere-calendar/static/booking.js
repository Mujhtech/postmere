'use strict';
(() => {
  const $ = id => document.getElementById(id);
  const token = location.pathname.split('/').pop();
  const endpoint = '/v1/calendar/public/' + encodeURIComponent(token);
  const zone = Intl.DateTimeFormat().resolvedOptions().timeZone;
  const day = new Intl.DateTimeFormat(undefined, { weekday:'long', month:'long', day:'numeric', timeZone:zone });
  const time = new Intl.DateTimeFormat(undefined, { hour:'numeric', minute:'2-digit', timeZone:zone });
  let selected = null, pending = null, sending = false;
  $('zone').textContent = 'Times shown in ' + zone.replaceAll('_',' ');
  const showStatus = (text, error=false) => { $('status').textContent=text; $('status').classList.toggle('error',error); };
  async function api(body) {
    const response = await fetch(endpoint, { method:body?'POST':'GET', headers:body?{'Content-Type':'application/json'}:{}, body:body?JSON.stringify(body):undefined, cache:'no-store', credentials:'omit', referrerPolicy:'no-referrer' });
    const value = await response.json();
    if (!response.ok) {
      const error=new Error(value.error?.message || 'The calendar is unavailable. Please try again later.');
      error.httpStatus=response.status; throw error;
    }
    return value;
  }
  async function load() {
    if (sending || pending) return;
    $('refresh').disabled=true; $('slots').replaceChildren(); $('booking-form').hidden=true; selected=null; pending=null;
    showStatus('Checking the host’s calendar…');
    try {
      const value = await api();
      $('title').textContent=value.title; $('description').textContent=value.description || 'Choose a time for your next conversation.';
      $('details').hidden=false; $('duration').textContent=value.duration_minutes+' minutes'; $('host-zone').textContent='Host: '+value.time_zone.replaceAll('_',' ');
      const groups = new Map();
      for (const slot of value.slots) {
        const label=day.format(new Date(slot.start));
        if (!groups.has(label)) groups.set(label,[]);
        groups.get(label).push(slot);
      }
      for (const [label,slots] of groups) {
        const heading=document.createElement('h3'); heading.className='day'; heading.textContent=label; $('slots').append(heading);
        const group=document.createElement('div'); group.className='day-slots'; $('slots').append(group);
        for (const slot of slots) {
          const button=document.createElement('button'); button.type='button'; button.className='slot'; button.textContent=time.format(new Date(slot.start)); button.setAttribute('aria-pressed','false'); button.setAttribute('aria-label',label+' at '+button.textContent);
          button.addEventListener('click',()=>{
            if(sending || pending)return;
            for(const other of document.querySelectorAll('.slot'))other.setAttribute('aria-pressed','false');
            button.setAttribute('aria-pressed','true'); selected=slot; pending=null; $('booking-form').hidden=false;
            $('selection').textContent=label+' · '+time.format(new Date(slot.start))+'–'+time.format(new Date(slot.end));
          }); group.append(button);
        }
      }
      showStatus(value.slots.length?'':'There are no available times on this link right now. Please contact the host.'); $('refresh').hidden=false;
    } catch(error) { showStatus(error.message,true); $('refresh').hidden=false; }
    $('refresh').disabled=false;
  }
  function confirm(result) {
    $('slots').hidden=true; $('booking-form').hidden=true; $('refresh').hidden=true; $('zone').hidden=true; $('status').hidden=true;
    $('confirmation').hidden=false; $('confirmation-title').textContent=result.status==='confirmed'?'You’re on the calendar.':'We’re checking your meeting.';
    $('confirmation-message').textContent=result.message;
    $('confirmation-time').textContent=day.format(new Date(result.start))+' · '+time.format(new Date(result.start))+'–'+time.format(new Date(result.end))+' · '+zone;
  }
  $('booking-form').addEventListener('submit',async event=>{
    event.preventDefault(); if(sending||!selected||!event.target.reportValidity())return;
    sending=true; $('submit').disabled=true; $('refresh').disabled=true; $('name').disabled=true; $('email').disabled=true; showStatus('Checking availability and creating your meeting…');
    for(const button of document.querySelectorAll('.slot'))button.disabled=true;
    pending ??= {client_id:crypto.randomUUID(),slot_id:selected.id,name:$('name').value.trim(),email:$('email').value.trim()};
    try {
      let result=await api(pending);
      for(let attempt=0; attempt<3 && ['checking','creating'].includes(result.status); attempt++) {
        await new Promise(resolve=>setTimeout(resolve,3000)); result=await api(pending);
      }
      if(result.status==='failed') {pending=null;throw new Error(result.message);}
      confirm(result);
    } catch(error) {
      // Retain the idempotency key after a network error. Re-submitting checks
      // the same reservation and cannot create another calendar invitation.
      if(error.httpStatus>=400 && error.httpStatus<500 && error.httpStatus!==408)pending=null;
      showStatus(pending ? 'We could not confirm the result. Check this booking’s status before choosing another time. '+error.message : error.message,true);
    }
    sending=false; $('submit').disabled=false; $('refresh').disabled=!!pending; $('name').disabled=!!pending; $('email').disabled=!!pending;
    if(pending && !$('booking-form').hidden)$('submit').textContent='Check booking status';
    for(const button of document.querySelectorAll('.slot'))button.disabled=!!pending;
  });
  $('refresh').addEventListener('click',load);
  load();
})();
