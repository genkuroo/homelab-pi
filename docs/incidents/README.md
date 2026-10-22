# Incident reports

Blameless postmortems for outages in this stack. Each report covers what users
saw, a timeline built from the logs, the root cause, and action items with their
status. The goal is to make sure the same failure doesn't happen twice. The first
pair below shows what happens when a follow-up adds detection but skips the root
cause.

| Date | Incident | Time to detect | Time to fix | Root cause fixed? |
|---|---|---|---|---|
| 2026-09-10 | [Containers lose DNS while showing "Up"](2026-09-10-container-dns-silent-failure.md) | ~15 h, by chance | ~31 h | No. It happened again |
| 2026-10-20 | [Wi-Fi drop takes out DNS for every container (repeat)](2026-10-20-container-dns-repeat.md) | 18 min, health check | ~18 h | Yes (`7e04457`) |
