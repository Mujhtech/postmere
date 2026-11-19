# Sender and recipient images

The inbox, reader and participant popover use a local Contacts photo when available. Turning on Gravatar in Settings → Privacy also lets Postmere look up an individual's photo using the SHA-256 hash of their normalized email address. [Gravatar identifiers](https://docs.gravatar.com/rest/hash/) and [avatar requests](https://docs.gravatar.com/sdk/images/).

For other participants, Postmere can show the website icon for their organization. The bundled Public Suffix List identifies its registrable domain, including boundaries between tenants on shared hosting. Lookups skip common personal mailbox providers, private network names and IP addresses. The icon request sends the registrable domain to Bitwarden's icon service. The service can see the requesting IP address and may fetch the icon from the organization. Settings → Privacy controls this lookup independently of images in message bodies. On upgrade, an existing preference to turn off automatic remote images also starts website lookups turned off. [Bitwarden website icons](https://bitwarden.com/help/website-icons/) and [Public Suffix List](https://publicsuffix.org/list/).

The profile popover identifies a website icon by its domain. The icon describes the website associated with the address. Mail providers that verify a particular message's BIMI evidence can also display a certified brand mark. [Apple's BIMI requirements](https://support.apple.com/en-us/108340).

Images and misses are cached in memory. Switching off either remote source clears its cache and cancels pending requests. When a photo or icon is unavailable, the avatar displays the participant’s initials.
