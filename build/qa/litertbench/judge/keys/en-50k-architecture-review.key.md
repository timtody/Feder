# Key: en-50k-architecture-review
Language: en · Characters: 49748 · Speakers: 5
## Must cover
- Atlas monolith is migrated with the strangler approach, piece by piece; no big-bang rewrite (a 2019 rewrite failed after 8 months)
- Broker: Kafka, self-hosted on the company's Kubernetes cluster with the Strimzi operator (KRaft); not RabbitMQ (reversed after Priya's replay/history argument); the existing RabbitMQ stays only for label printing
- Kafka sizing: 5 brokers in production across 3 zones, replication factor 3, min in-sync replicas 2; 3 brokers in staging
- Shipment events topic: 24 partitions, keyed by shipment ID for per-shipment ordering
- Retention: 7 days by default, 30 days for shipment events; Kafka is not the archive (older data goes to object storage)
- Every event has an Avro schema in a schema registry; backward compatibility checked in CI (registry product still to be chosen)
- Data ownership: each service owns its data (own database and credentials on a new shared Postgres 16 cluster); no service reads another service's tables
- Customer master data stays in Atlas until phase 3, behind a small read API (built by Daniel's team as part of phase 1)
- Atlas changes leave via CDC with Debezium (Kafka Connect, 2 workers) plus a translation/anti-corruption layer; new services use the outbox pattern; no dual writes
- Consumers must be idempotent; events carry an event ID (UUID) and a per-shipment version number (Atlas `rev` column)
- Topics are created via pull requests to a config repo; naming domain.entity.event.version; SRE approves; schemas in the same PR
- Shipment status changed events are "fat" (full shipment state, customer master data only as a reference ID); payload shape of other event types left open
- Phase order: 1 tracking, 2 dispatch, 3 billing (billing and dispatch swapped from the pre-read)
- Phase 1: 4 weeks shadow mode, switch after 7 consecutive days below 0.1% mismatch; pilot hub Rotterdam; go-live 2 February 2027; all hubs by 31 March 2027
- Outage follow-up: invoice batch moves to the read replica, the SELECT FOR UPDATE is removed, batch schedule changes need review
- Outage root cause: invoice batch ran at 10:00 instead of 02:00 (scheduler config/UTC change in August) and locked the shipments table; deeper cause is billing and tracking sharing one database
- Cost taken to the steering committee: €21,500/month infrastructure + one senior SRE hire (~€105,000/year, from Q1 2027) + €340,000 one-off (±25%)
- Monitoring (consumer lag, broker disk, under-replicated partitions) must be in place before phase 1 go-live; the SRE hire must be in place before phase 2 go-live
- Two game days (kill a broker and a consumer in pre-prod) before Rotterdam go-live
- Open questions: long-term owner of customer master data (session with CRM team); Kafka Streams vs Flink for ETA (stored procedure stays in phase 1); payload shape for other event types; cross-region DR (after phase 2); who upgrades the Atlas Postgres 11 and when; which schema registry; whether Ostmark Paper invokes its SLA clause
## Facts (numbers, dates, names)
- Speakers: Maren (facilitator), Daniel (principal engineer on Atlas), Priya (data lead), Tomasz (SRE lead, team of 4), Speaker 4 (finance/controlling, on the phone)
- Atlas: 14 years old, ~1.2 million lines of Java, one Spring app, one Postgres 11 database (out of support); started as dispatch tool for the Leeds depot
- Deploys every 2 weeks (Wednesday night), ~3 hours each; deploy coordination costs ~15% of team time (June survey)
- 4.8 million scan events per day; peak ~1,900 events/s sustained (last November), spikes ~2,300; design target 3x headroom ≈ 6,000 events/s
- Event size ~1.5 KB; 30 days of shipment events ≈ 200 GB raw, ~600 GB with replication
- Outage: 23 September (Tuesday), 10:14 to 14:26, 4 h 12 min; connection pool of 200 exhausted; 37,000 queued scans flushed on recovery; ~2,300 late delivery notifications
- SLA credits: €62,000 paid to Brennholt Retail; Ostmark Paper could claim ~€18,000 more (worst case ~€80,000)
- Customer master data: 4 tables, 114 columns in Atlas
- Rotterdam = ~12% of scan volume
- Cost breakdown of revision: 14,000 + cross-zone traffic 3,500 + full-time pre-prod 2,500 + observability licence 1,100 + backups/object storage 400 = €21,500/month
- Phase 1 effort: 4 engineers for ~5 months; 2 contractors for Kafka/Debezium early on
- Atlas maintenance window (logical replication, wal_level=logical): 15 November
- General change freeze from 19 December; billing freeze every year 1 December to 20 January
- Steering committee: 12 November; next review of this group: 5 November (2 hours)
- Phase 2 dispatch target 30 June 2027 (design done end of Q1, date confirmed in March); phase 3 billing target October 2027
- Atlas not expected to be retired before 2029
## Tasks
- Tomasz: finalise the 23 September post-mortem and move the invoice batch to the read replica (24 October)
- Maren: decision records for the broker and the phase order, updated migration document (28 October)
- Priya: data ownership matrix plus schema registry comparison (31 October)
- Tomasz: Kafka staging cluster, 3 brokers, Strimzi, monitoring (7 November)
- Speaker 4: revised cost model with €21,500/month and the SRE hire (10 November, before the 12 November steering committee)
- Daniel: outbox and CDC spike against a staging copy of the shipments table (14 November)
- Tomasz and Daniel: enable logical replication on the Atlas database (maintenance window 15 November)
- Priya: shipment event schemas v1 in Avro: status changed, scan received, exception (21 November)
- Tomasz: production Kafka cluster (12 December)
- Tomasz: two game days (January; the second a week before 2 February)
- Maren: set up the customer master data session with the CRM team (end of November)
- Daniel: customer data read API (part of phase 1, no separate date)
- Speaker 4: track whether Ostmark Paper invokes the SLA clause (no date)
## Traps
- Broker: tentatively RabbitMQ (already in house, Daniel's proposal) → Kafka on Strimzi; RabbitMQ only for label printing
- Monthly infrastructure cost: €14,000/month (Tomasz) → €21,500/month (finance's revision incl. cross-zone traffic, pre-prod, licence, backups), plus SRE hire separately
- Phase order: tracking, billing, dispatch (pre-read draft) → tracking, dispatch, billing
## Misheard words
- Rabbit and queue = RabbitMQ
- Stream Z = Strimzi
- item potent = idempotent
- Avril = Avro
- the bee zoom = Debezium
