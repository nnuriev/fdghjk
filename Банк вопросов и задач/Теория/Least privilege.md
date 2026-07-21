---
aliases:
  - "Теоретический вопрос: Least privilege"
tags:
  - область/бэкенд
  - тема/безопасность
  - принцип/наименьшие-привилегии
  - тип/вопрос
статус: проверено
---

# Least privilege

## Вопрос

Как работает «Least privilege» и какие ограничения, failure modes и trade-offs нужно учитывать в backend-системе?

## Короткий ориентир

Least privilege — дать subject только те полномочия, которые нужны для конкретной задачи, над минимальным набором resources, в допустимом контексте и на ограниченное время. «Read-only», внутренняя сеть и одна общая service role не доказывают минимальность: чтение может раскрывать все PII, inherited policy — добавлять admin actions, а shared identity — объединять blast radius всего fleet.

Принцип реализуется как lifecycle. Сначала разделяют identities и data/control plane, затем описывают required actions и resources, выдают narrow policy или short-lived elevation, проверяют effective permissions и negative cases, наблюдают фактическое использование, регулярно убирают лишнее. Отсутствие вызова в коротком audit window не доказывает ненужность права: seasonal jobs, incident recovery и disaster failover моделируют отдельно.

Least privilege уменьшает ущерб после компрометации, но не предотвращает саму уязвимость. Захваченный thumbnail worker всё ещё способен испортить разрешённые thumbnails; задача policy — не дать ему удалить original objects, прочитать другие tenants или менять IAM.

Полный разбор: [[20 Бэкенд/Least privilege|Least privilege]].

## Варианты follow-up

- С какой ближайшей альтернативой сравнивается подход и по какому признаку выбирать?
- Какое неверное предположение приводит к наиболее опасному failure mode?
- В каких условиях подход полезен, а в каких опасен?

## Варианты формулировки и происхождение

- «Проектирование сервиса хранения секретов — нужно исходное условие; база: Управление секретами, Least privilege.» — [[Авито/roadmap#System design и проектирование|Авито/roadmap, раздел «System design и проектирование»]].

## Источники

- [NIST SP 800-53 Rev. 5: Security and Privacy Controls for Information Systems and Organizations](https://csrc.nist.gov/pubs/sp/800/53/r5/upd1/final) — NIST, SP 800-53 Rev. 5, release 5.2.0 от 2025-08-27; control AC-6 и enhancements, проверено 2026-07-18.
- [NIST SP 800-207: Zero Trust Architecture](https://csrc.nist.gov/pubs/sp/800/207/final) — NIST, SP 800-207, август 2020, проверено 2026-07-18.
- [RFC 9700: Best Current Practice for OAuth 2.0 Security](https://www.rfc-editor.org/rfc/rfc9700.html) — IETF, BCP 240 / RFC 9700, январь 2025; section 2.3 об access token privilege restriction, проверено 2026-07-18.
- [AWS IAM: Policies and permissions](https://docs.aws.amazon.com/IAM/latest/UserGuide/access_policies.html) — Amazon Web Services, IAM documentation о least privilege и refinement по access activity, проверено 2026-07-18.
- [AWS IAM Access Analyzer: custom policy checks](https://docs.aws.amazon.com/IAM/latest/UserGuide/access-analyzer-checks-validating-policies.html) — Amazon Web Services, IAM Access Analyzer documentation о new/specified/public access checks, проверено 2026-07-18.
- [NIST SP 800-204: Security Strategies for Microservices-based Application Systems](https://csrc.nist.gov/pubs/sp/800/204/final) — NIST, SP 800-204, август 2019, проверено 2026-07-18.
