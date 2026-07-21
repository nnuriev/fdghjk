---
aliases:
  - "Теоретический вопрос: Availability, fault tolerance, RPO, RTO и error budget"
tags:
  - область/распределённые-системы
  - тема/надёжность
  - тип/вопрос
статус: черновик
---

# Availability, fault tolerance, RPO, RTO и error budget

## Вопрос

Как связать availability, fault tolerance, RPO/RTO и error budget с конкретной failure model?

## Короткий ориентир

Availability измеряет долю пригодного сервиса, fault tolerance описывает способность продолжать работу при заданных отказах. RPO ограничивает допустимую потерю данных, RTO — время восстановления. Error budget переводит SLO в допустимый объём неуспеха за окно и помогает выбирать скорость изменений относительно reliability risk.

Полные разборы:

- [[40 Распределённые системы/Disaster recovery|Disaster recovery]]
- [[70 Практические кейсы/Error budgets|Error budgets]]
- [[70 Практические кейсы/Availability и durability calculations|Availability и durability calculations]]

## Варианты follow-up

- Какая failure model стоит за заявленной fault tolerance?
- Чем RPO отличается от RTO?
- Как error budget связан с SLO window?

## Варианты формулировки и происхождение

- [[CurseHunter/5785/04 Распределённое хранение данных#Backup и replication|Backup и replication]] — вопрос о разных failure classes, RPO/RTO и restore drill.
- [[CurseHunter/5785/01 Интервью, требования и нагрузка#Availability, reliability и fault tolerance — чем отличаются?|CourseHunter 5785, свойства надёжности]].
- [[CurseHunter/7091/01 Основы отказоустойчивости и SRE#5. SLI, SLO, SLA и error budget|CourseHunter 7091, error budget]].
- [[CurseHunter/7091/01 Основы отказоустойчивости и SRE#7. Проверка надёжности: load, stress и chaos|CourseHunter 7091, chaos]].

## Источники

- [NIST SP 800-34 Rev. 1: Contingency Planning Guide for Federal Information Systems](https://nvlpubs.nist.gov/nistpubs/legacy/sp/nistspecialpublication800-34r1.pdf) — NIST, Rev. 1 Final, 2010, проверено 2026-07-18.
- [REL13-BP02 Use defined recovery strategies to meet the recovery objectives](https://docs.aws.amazon.com/wellarchitected/2022-03-31/framework/rel_planning_for_recovery_disaster_recovery.html) — Amazon Web Services, Well-Architected Framework, редакция 2022-03-31, проверено 2026-07-18.
- [REL09-BP04 Perform periodic recovery of the data to verify backup integrity and processes](https://docs.aws.amazon.com/wellarchitected/2022-03-31/framework/rel_backing_up_data_periodic_recovery_testing_data.html) — Amazon Web Services, Well-Architected Framework, редакция 2022-03-31, проверено 2026-07-18.
- [Disaster recovery planning guide](https://docs.cloud.google.com/architecture/dr-scenarios-planning-guide) — Google Cloud Architecture Center, last reviewed 2024-07-05, проверено 2026-07-18.
- [Implementing SLOs](https://sre.google/workbook/implementing-slos/) — Google, The Site Reliability Workbook, глава 2, проверено 2026-07-18.
- [Alerting on SLOs](https://sre.google/workbook/alerting-on-slos/) — Google, The Site Reliability Workbook, глава 5, проверено 2026-07-18.
- [Example Error Budget Policy](https://sre.google/workbook/error-budget-policy/) — Google, The Site Reliability Workbook, приложение B, проверено 2026-07-18.
- [Service Level Objectives](https://sre.google/sre-book/service-level-objectives/) — Google, Site Reliability Engineering, глава 4, проверено 2026-07-18.
- [Availability](https://docs.aws.amazon.com/wellarchitected/latest/reliability-pillar/availability.html) — AWS Well-Architected Framework, Reliability Pillar, проверено 2026-07-18.
- [Availability Table](https://sre.google/sre-book/availability-table/) — Google, Site Reliability Engineering, таблица допустимой недоступности, проверено 2026-07-18.
- [Data availability and durability](https://cloud.google.com/storage/docs/availability-durability) — Google Cloud Storage, актуальная документация, проверено 2026-07-18.
- [Data Integrity: What You Read Is What You Wrote](https://sre.google/sre-book/data-integrity/) — Google, Site Reliability Engineering, глава 26, проверено 2026-07-18.
- [Composite Cloud Availability](https://cloud.google.com/blog/products/devops-sre/composite-cloud-availability) — Google Cloud, DevOps & SRE, 2022, проверено 2026-07-18.
