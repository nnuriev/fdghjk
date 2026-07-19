---
aliases:
  - Data locality
  - Локальность данных
  - Data residency
  - Data gravity
tags:
  - область/распределённые-системы
  - тема/мультирегиональность
  - архитектура/размещение-данных
статус: проверено
---

# Data locality

## TL;DR

**Data locality** — размещение вычислений и данных достаточно близко друг к другу и к пользователю, чтобы выполнить требования latency, стоимости, failure isolation и управления данными. Она шире **data residency**: residency прежде всего задаёт допустимое место хранения in-scope data at rest. Ограничения на processing и access зависят от закона и service contract и проверяются отдельно. Locality также учитывает network distance, data gravity, ownership и место выполнения транзакции.

Решение принимают для полного жизненного цикла данных. Primary может быть в требуемом регионе, а replica, backup, search index, telemetry, support dump или model-training export — за его пределами. Поэтому архитектура фиксирует data classes, allowed locations, write owner, derived copies, encryption keys, routing и процедуру миграции. Маркетинговое название региона не заменяет проверку конкретного сервиса и договора; заметка не является юридической консультацией.

## Область применимости

Заметка рассматривает locality в геораспределённых backend-системах. Официальные правила облачных сервисов изменяются и зависят от выбранной услуги; ссылки проверены 2026-07-18, но юридические требования нужно подтверждать с ответственными за compliance и актуальными контрактами.

## Ментальная модель

У данных есть «центр тяжести» (**data gravity**): большой объём дорого и медленно перемещать, поэтому compute, indexes и analytics стремятся оказаться рядом. Но один объект образует граф копий:

```text
source row -> replicas -> cache -> search index -> event -> backup
          \-> logs/support export -> analytics/model features
```

Locality доказана только тогда, когда для каждой стрелки известны место назначения, retention и механизм удаления. Блокировка cross-region API на основном пути не поможет, если CDC по умолчанию выгружает payload в global topic.

Есть три независимых вопроса:

1. где данные физически хранятся;
2. где они обрабатываются и кто имеет доступ;
3. откуда приходит critical-path запрос и сколько network boundaries он пересекает.

## Как устроено

### Классификация и placement policy

Сначала данные делят по требованиям: public catalog, account profile, payment ledger, secrets, telemetry, backups. Для класса задают allowed regions, required replicas, срок хранения, допустимые производные данные и recovery location. Tenant home region или jurisdiction становятся частью metadata, а не условием в коде каждого сервиса.

Policy должна различать control-plane metadata и payload. Глобальный каталог `tenant_id -> home_region` может не содержать персональных данных и позволять маршрутизировать request, тогда как сам profile остаётся региональным. Но если каталог включает email или свободный support note, он уже меняет compliance boundary.

### Routing к данным

Request направляют не только к ближайшему compute, а к месту authority. Возможны:

- geo-routing сразу в home region;
- local frontend, который пересылает write владельцу;
- read replica рядом с пользователем и writes в home region;
- partition ownership, где key однозначно определяет region;
- controlled multi-writer с conflict semantics.

Local frontend с удалённой database не уменьшает write latency: WAN просто скрыт внутри service call. Для read-after-write local cache может вернуть stale value; session token или routing к owner восстанавливает нужную гарантию.

### Leader и replica placement

В consensus-replicated store latency commit зависит от расположения voting replicas и leader. Spanner instance configuration задаёт географию replicas, а leader placement влияет на write latency. Optional read-only replicas не входят в write quorum и приближают stale reads; strong read может потребовать consultation с leader, поэтому его latency проверяют отдельно. Значит «данные есть в регионе» ещё не означает, что запись выполняется локально или strong read будет локальным.

При asynchronous replication local write дешевле, но копия в другой географии появляется позже. Если geography запрещена, даже временная replica или disaster-recovery backup там недопустимы по политике. Если удалённая копия обязательна для DR, требования residency и resilience приходится согласовать явно.

### Derived data и operational surfaces

Логи, traces и metrics часто содержат identifiers, query parameters или payload fragments. Central observability pipeline способен незаметно вывести данные из home region. Нужны redaction у источника, regional collectors и schema allowlist.

Backup, snapshot и object-store replication имеют собственные location settings. Ключи шифрования, secret managers, customer support tools, crash dumps и third-party processors входят в тот же data flow review. Удаление исходной строки не завершено, пока не определено поведение indexes, caches, events и backup retention.

### Миграция между регионами

Перенос tenant — распределённая state transition:

1. создать target copy и непрерывно догнать изменения;
2. проверить checksum/version и совместимость schema;
3. остановить или перенаправить writes через fencing epoch;
4. переключить routing metadata атомарно относительно authority;
5. выдержать rollback window;
6. удалить старые копии по проверяемой процедуре.

Dual write без authority protocol создаёт divergence. DNS switch без session drain оставляет старые clients. Удаление source сразу после cutover лишает rollback; бесконечное хранение нарушает цель migration. Эти состояния должны быть видны оператору.

## Пример или трассировка

Tenant `t42` требует хранить customer profiles в регионе EU. Catalog и public product data могут быть глобальными.

1. Global routing читает минимальный каталог `(t42 -> eu-west)` и отправляет authenticated profile requests в EU cell.
2. Profile database, local replicas, search index и outbox находятся в разрешённой географии. Events разделены: `CustomerEmailChanged` остаётся в regional broker, а глобальная analytics получает только необратимо агрегированный счётчик без customer ID.
3. Observability agent пытается отправить полный HTTP body в global trace backend. Policy test блокирует deployment: основная база была локальной, но trace создал запрещённую копию.
4. Backup policy хранит encrypted snapshots во второй разрешённой EU location. Restore test поднимает их там же и проверяет, что ключ доступен без исходного региона.
5. При миграции `t42` в другой EU region новая ownership epoch не позволяет старой cell принять поздний write.

Этот сценарий одновременно решает latency и residency, но не доказывает соответствие конкретному закону. Доказательство даёт инвентаризация потоков плюс актуальная юридическая интерпретация.

## Trade-offs

Региональная изоляция уменьшает latency и blast radius, но дублирует инфраструктуру, усложняет analytics и ограничивает глобальные joins. Центральное хранилище проще эксплуатировать, однако пользователи далеко от него платят WAN latency, а одна политика размещения применяется ко всем данным.

Home-region ownership сохраняет простой конфликтный контракт; переезд tenant становится сложным. Multi-writer уменьшает local latency перемещающихся пользователей, но требует merge и может быть несовместим с глобальными уникальными инвариантами.

Агрегация и tokenization позволяют глобальные отчёты без raw payload, но уменьшают детализацию и требуют доказать, что обратная идентификация действительно невозможна в принятой модели угроз.

## Типичные ошибки

- **Неверное предположение:** region primary означает, что все копии локальны. **Симптом:** payload находится в global logs или backup. **Причина:** проверен только source store. **Исправление:** data-flow inventory всех derived и operational copies.
- **Неверное предположение:** ближайший application instance гарантирует низкую latency. **Симптом:** write делает несколько WAN hops. **Причина:** data authority осталась далеко. **Исправление:** измерять полный critical path и размещать compute относительно owner.
- **Неверное предположение:** residency — только настройка облака. **Симптом:** support export или сторонний processor меняет geography. **Причина:** организационные потоки вне infrastructure diagram. **Исправление:** единая policy для services, people, tooling и vendors.
- **Неверное предположение:** tenant можно перенести копированием и DNS. **Симптом:** поздние writes расходятся между регионами. **Причина:** нет ownership epoch и controlled cutover. **Исправление:** migration state machine, fencing, verification и deletion proof.

## Когда применять

Явная locality нужна при глобальной аудитории, чувствительной latency, большой data gravity, regional isolation или требованиях residency. Для небольшого продукта без таких ограничений один хорошо выбранный регион часто безопаснее преждевременной географии.

Перед выбором сервиса составьте data inventory и проверяйте его регулярно: новые поля, integrations и telemetry меняют placement. Тест должен обнаруживать cross-region endpoint, backup location и неразрешённый event route до production, а не только после аудита.

## Источники

- [Spanner regional, dual-region, and multi-region configurations](https://cloud.google.com/spanner/docs/instance-configurations) — Google Cloud, документация Spanner, проверено 2026-07-18.
- [Spanner replication](https://cloud.google.com/spanner/docs/replication) — Google Cloud, voting/read-only replicas, write quorum и strong/stale read paths, проверено 2026-07-18.
- [Azure geographies and regions](https://learn.microsoft.com/en-us/azure/reliability/regions-overview) — Microsoft Azure, документация, проверено 2026-07-18.
- [Data residency in Google Cloud](https://docs.cloud.google.com/assured-workloads/docs/data-residency) — Google Cloud Assured Workloads, документация, проверено 2026-07-18.
- [AWS Data Privacy FAQ](https://aws.amazon.com/compliance/data-privacy-faq/) — Amazon Web Services, сведения о выборе региона и перемещении customer content, проверено 2026-07-18.
