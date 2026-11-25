# Draft: the relay section of twr's privacy policy

Status: draft, 2026-11-23, from §11.3 of the phone pairing design and §14 of `docs/relay-protocol.md` (twr). It goes into twr's `docs/privacy.md` once the relay ships, and a lawyer should read it before then. Placeholders are in square brackets. The notes at the end are for the maintainer and don't go into the policy.

That page currently says "the project runs no service that your data passes through". The relay changes that, so the sentence must change in the same edit.

---

## twr's relay

The phone apps and hubs can reach each other through a relay when the phone can't reach the hub directly. twr's own relay runs in two places, `eu.relay.twr.tools` and `us.relay.twr.tools`. It is operated by CGIS LLC, [OPERATOR ADDRESS], reachable at [CONTACT EMAIL, for example privacy@twr.tools].

Your hub uses it by default (`[mobile] relay = "twr"`). Runners and hubs linked with `twr-link` may use it to find each other.

### What the relay can and can't see

The relay forwards connections and can't read them. A phone's connection is encrypted end to end to its hub's key, and the relay passes it on without decrypting it. Your messages, files, voice, terminal sessions, device tokens and pairing codes never reach the relay in readable form.

To do its job, the relay handles:

- **IP addresses** of hubs, phones and runners that connect to it.
- **Hub relay names**, which are derived from a hub's public key. They aren't your name or your machine's name.
- **Phone credential tags**, values derived from a key your hub gave the phone. They change every 5 minutes.
- **iroh endpoint ids and admissions.** An endpoint id is a runner's or hub's public key. An admission is a signed note saying which endpoints may use the relay, and until when.
- **Signed records** that hubs and runners publish so others can find them. They hold the publisher's network addresses, and are public by design, like DNS.
- **Connection times and byte counts.**

### Why

To forward connections between your devices, and to prevent abuse. The relay enforces limits per hub and per address, such as how many phones, how many connections and how many bytes, and it blocks hubs or addresses that abuse it.

### How long it keeps it

| What | How long |
|---|---|
| Connection records (address, time, bytes) | At most 7 days |
| Daily byte totals per hub, for the monthly limit | At most 30 days |
| iroh admissions | Until they expire: 15 minutes for one that is about to pair, at most 30 days for a pair |
| Signed records | 2 hours after they were stored; not written to disk |
| A hub's "moved" note, left for its offline phones when it changes relays | 90 days |
| Logs | The relay writes no logs with IP addresses, hub names, tags, keys or content, at any log level. It keeps counters (connections, bytes, refusals by reason) without them. |

### Where

On servers rented from DigitalOcean, LLC (USA), in Frankfurt, Germany, and in New York, United States. Each hub keeps a connection to both regions so that one can fail without an outage. That means your hub's and your phones' IP addresses reach the US server too, wherever you are. [TRANSFER MECHANISM: for example the EU standard contractual clauses in DigitalOcean's data processing agreement. To be confirmed.]

Let's Encrypt issues the relay's own certificates. It learns the relay's names and the operator's contact address, and nothing about you.

### Legal basis (EU and UK)

[A lawyer should confirm this wording.] We process this data to provide the service you asked for, which is reaching your hub through the relay (Art. 6(1)(b) GDPR). We also process it to keep the relay working and free of abuse, a legitimate interest (Art. 6(1)(f) GDPR). You can object to it by turning the relay off, as described below.

### How to avoid it

- Set `[mobile] relay = "none"` on your hub. The hub then registers nowhere, and turning it off also deletes the hub's phone credentials at the relay. Your phone then reaches the hub only directly.
- Or run your own relay (`twr relay serve --install` on a server of yours) and point your hub at it. Then this section doesn't apply, and you are the operator.

### Your rights

You can ask for access to, or deletion of, data about you at [CONTACT EMAIL]. The relay links no data to a person, only to keys and addresses. To find data about you, we need your hub's relay name (`[COMMAND THAT PRINTS IT]`), and we can only find what is still within the periods above. You can also complain to your data protection authority.

---

## Notes for the maintainer (not part of the policy)

- **Check against the code before publishing.** The retention rows come from the design and `docs/relay-protocol.md` §5.7, §9, §10.2 and §14. As specified, the relay keeps per-address counters only in memory for the limit windows and writes no address anywhere, so the 7 days is a ceiling. If the implementation keeps less, the policy may say less. It must never keep more.
- **Runners and `twr-link`.** If `twr-link` uses twr's relay by default, the policy must say so where it describes runners too.
- **The status page and `/v1/hubs/<label>`** reveal to a phone holding a credential whether its hub is online. No new data, but worth a line if a reviewer asks.
- **US region and EU users.** DigitalOcean's DPA and its transfer mechanism (SCCs, or the EU-US Data Privacy Framework if DigitalOcean is certified) are *unverified*. Read the current DPA, and sign it in the DigitalOcean account if that takes a click.
- **Store forms, all unverified.** I haven't checked how either store classifies IP addresses and connection metadata that pass through a developer-operated relay. Open questions:
  - *App Store privacy label.* Does this count as "data collected" by the developer? Possibly under Identifiers or Diagnostics ("other diagnostic data"), and if so "not linked to the user's identity" and "not used for tracking". Apple's definitions say whether data that only passes through a server counts as collected. Read them.
  - *Google Play Data safety.* Possibly "Device or other IDs" or "App activity", collected, not shared, encrypted in transit, with deletion on request. Also check whether IP addresses count as "Approximate location" under Google's guidance.
  - Both forms must cover the default setting (`relay = "twr"`), not only what's possible when the relay is off.
- **Operator.** CGIS LLC (decided 2026-11-25). Its postal address (`[OPERATOR ADDRESS]`) and the contact address (`[CONTACT EMAIL]`) are still to fill in.
