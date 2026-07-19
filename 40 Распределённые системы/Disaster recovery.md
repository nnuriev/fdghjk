---
aliases:
  - Disaster recovery
  - Аварийное восстановление
  - DR plan
tags:
  - область/распределённые-системы
  - тема/аварийное-восстановление
  - практика/непрерывность-бизнеса
статус: проверено
---

# Disaster recovery

## TL;DR

Disaster recovery (DR) — проверяемая способность вернуть бизнес-процесс после разрушительного события. Резервный регион, replica и архив snapshots по отдельности этой способности не дают. Восстановление закончено, когда критический пользовательский сценарий снова работает с допустимыми данными, capacity, доступами, безопасностью и внешними зависимостями.

Проектирование начинается с business impact analysis (BIA): какие процессы страдают, как меняется ущерб со временем и потерей данных, кто принимает решение о переключении. Из этого выводят [[40 Распределённые системы/RPO и RTO|RPO и RTO]], затем выбирают стратегию, инвентаризируют зависимости и пишут исполнимый runbook.

Replication не заменяет backup. Она быстро переносит состояние, а вместе с ним — ошибочный `DELETE`, logical corruption или bad deploy. Для возврата к чистой точке нужны независимые версии, snapshots или point-in-time recovery с подходящей изоляцией и retention. Их ценность доказывает restore, а не зелёный статус backup job.

## Область применимости

Заметка рассматривает восстановление backend workload после потери инфраструктуры, данных или корректного программного состояния. Incident response ограничивает инцидент, business continuity охватывает работу организации шире IT, DR возвращает системы и данные. Владельцы и handoff должны быть записаны заранее.

Версионная область: NIST SP 800-34 Rev. 1 Final (2010), AWS Well-Architected 2022-03-31 и Google Cloud DR Planning Guide, last reviewed 2024-07-05; проверено 2026-07-18.

## Ментальная модель

DR удобно видеть как цепь доказательств:

```text
business process
  -> critical user journey
  -> application and data
  -> identity, network, keys, artifacts, vendors
  -> restore/rebuild procedure
  -> validation and measured recovery
```

Разрыв любой стрелки оставляет «восстановленную» систему бесполезной: база поднялась, но ключ расшифрования остался в потерянном регионе или DNS ведёт на старую площадку. Поэтому unit восстановления — end-to-end service, а не отдельная VM.

Recovery point тоже часть доказательства. Нужно показать, что выбранная копия доступна, читается поддерживаемой версией ПО, согласована с остальными stores и относится к моменту до corruption.

## Как устроено

### BIA и сценарии отказа

NIST ставит BIA перед выбором технологии. Анализ связывает system components с mission/business processes, interdependencies и допустимым ущербом.

Для workload фиксируют несколько событий: потеря zone/region, недоступность identity или network, уничтожение primary storage, ransomware, массовое удаление, несовместимая schema migration, bad deploy. Одна архитектура ведёт себя по-разному. Async replica помогает при потере диска, но почти сразу воспроизводит логическую ошибку; backup возвращает старое состояние, но увеличивает время recovery.

### Dependency inventory

Dependency map строят от critical journey наружу. В неё входят базы, object storage, queues, DNS и traffic control, IAM, secrets и encryption keys, certificates, container registry и source artifacts, CI/CD, observability, quota/capacity, лицензии, сторонние API и доступ операторов. У каждой зависимости спрашивают:

- переживает ли она тот же failure scenario;
- можно ли восстановить или воспроизвести её без primary site;
- какой её RTO/RPO нужен, чтобы итоговый workload уложился в свои цели;
- кто имеет право выполнить recovery и откуда возьмёт credentials.

Общий control plane способен одновременно вывести из строя primary и recovery environment. Поэтому артефакты, runbook и emergency access держат в месте, доступном во время заявленного disaster.

### Выбор стратегии

AWS располагает распространённые варианты по росту стоимости и сложности и по снижению recovery time:

- **backup and restore:** данные и конфигурация сохранены, инфраструктуру разворачивают и данные восстанавливают после события;
- **pilot light:** core data services работают в recovery site, остальной stack создают при переключении;
- **warm standby:** уменьшенный, но функциональный workload уже запущен и масштабируется до production capacity;
- **multi-site active-active:** несколько площадок обслуживают traffic постоянно и должны выдержать evacuation одной из них.

Это не готовые SLA. Конкретный результат зависит от объёма, bandwidth, backlog, quotas, control-plane availability и числа ручных шагов. [[40 Распределённые системы/Active-active и active-passive|Active-active]] сокращает часть переключения, но усложняет write authority и не возвращает чистую версию данных после corruption. [[40 Распределённые системы/Multi-region architecture|Multi-region architecture]] тоже остаётся лишь основой, пока failover и failback не проверены.

### Replication, backup и clean recovery point

[[30 Данные/Репликация данных|Репликация]] уменьшает lag между площадками и помогает продолжить работу после инфраструктурного отказа. Она оптимизирована на распространение подтверждённых изменений, поэтому корректно размножает ошибку приложения. AWS прямо требует дополнять replicas versioning или point-in-time recovery и делать backups данных в recovery site.

Backup должен иметь отдельный failure domain, retention и защиту от удаления теми же credentials. Нужны каталог копий, checksum/integrity validation, доступные encryption keys и известная совместимость restore tooling. При logical corruption выбирают последнюю **чистую** точку; более свежая уже может содержать ошибку. Transaction logs после неё можно replay-ить лишь до плохой операции или с фильтрацией; слепой replay вернёт повреждение.

### Runbook и state machine восстановления

Runbook задаёт явные состояния и preconditions:

1. обнаружить и объявить disaster, назначить incident commander;
2. остановить распространение ошибки: freeze writes, revoke credentials, fence старый primary;
3. выбрать и зафиксировать clean recovery point;
4. rebuild инфраструктуру и restore данные;
5. восстановить dependencies, применить schema/config и проверить security controls;
6. выполнить integrity checks и critical user journeys под ожидаемой нагрузкой;
7. переключить traffic, наблюдать ошибки и reconciliation backlog;
8. спланировать failback, сохранить evidence и обновить план.

Команда «восстановить БД» слишком расплывчата. Нужны конкретные действия, входы, ожидаемый результат, timeout, rollback и ответственный. Автоматизация уменьшает ошибки и время, но решение о разрушительном promotion или выборе старой точки часто оставляют явно авторизуемым.

### Game days и измеренная capability

NIST включает testing, training, exercises и maintenance в сам цикл contingency planning. Game day должен проходить путь целиком: потерять обычный канал доступа, поднять окружение, восстановить данные, войти под реальными ролями, пропустить synthetic или shadow transaction и выполнить failback. Tabletop полезен для ролей, но не измеряет bandwidth, quota и время replay.

Фиксируют timestamps каждого этапа, фактическую recovery point, integrity result и момент готовности user journey. AWS различает целевые RTO/RPO и измеренную recovery time/point capability. Если capability хуже цели, меняют стратегию либо пересматривают цель с business owner; красивый документ разрыв не закрывает.

## Пример или трассировка

Для сервиса заказов задано: RPO 5 минут, RTO 45 минут. В 10:02 bad deploy начинает портить адреса, и async replica воспроизводит те же записи.

1. В 10:07 проверка бизнес-инварианта замечает corruption; в 10:09 команда блокирует writes и отзывает deploy credentials.
2. Replica не подходит: её данные уже повреждены. Каталог PITR показывает проверенную точку 10:00, то есть за 2 минуты до начала disruption.
3. Recovery stack строится из известного IaC и предыдущего application artifact. Database восстанавливается к 10:00; очередь и object store приводятся к согласованной позиции либо их расхождения попадают в reconciliation list.
4. В 10:34 проходят checks целостности, login, создание и чтение тестового заказа. В 10:38 traffic переключён, capacity и error rate остаются допустимыми.

Фактическое окно потери относительно начала corruption — 2 минуты, end-to-end recovery заняло 36 минут. Обе цели выполнены. «Replica lag был 10 секунд» здесь ничего не доказывал: replica быстро сохранила неправильное состояние.

## Trade-offs

Чем короче RTO/RPO, тем больше постоянной capacity, синхронной репликации, automation и операционной сложности. Cold restore дешевле в штатном режиме, но платит provisioning и replay во время аварии.

Immutable/versioned backups защищают от удаления и corruption, но увеличивают storage, governance и время поиска clean point. Длинный transaction log улучшает выбор recovery point, однако большой replay способен ухудшить RTO. Частые full snapshots уменьшают replay, потребляя I/O и место.

Автоматический failover сокращает decision time при хорошо определённом инфраструктурном отказе. При logical corruption он может быстрее переключить traffic на уже испорченную копию. Detection и promotion policy должны различать эти события.

## Типичные ошибки

- **Неверное предположение:** replica — это backup. **Симптом:** нет чистой точки восстановления. **Причина:** ошибка реплицировалась. **Исправление:** независимые versioned/PITR copies и restore test.
- **Неверное предположение:** второй регион означает готовый DR. **Симптом:** recovery упирается в IAM, key, artifact или quota. **Причина:** нет dependency inventory. **Исправление:** восстановить critical journey целиком на game day.
- **Неверное предположение:** успешный backup job доказывает восстановимость. **Симптом:** snapshot не читается или restore превышает RTO. **Причина:** проверялась запись, а не возврат данных. **Исправление:** регулярный isolated restore с integrity checks.
- **Неверное предположение:** RTO завершился при старте VM. **Симптом:** метрика зелёная, пользователи ещё не могут оформить заказ. **Причина:** измерен компонент вместо сервиса. **Исправление:** end-to-end start/end events и бизнес-валидация.
- **Неверное предположение:** runbook остаётся верным без упражнений. **Симптом:** команды, роли и endpoints устарели. **Причина:** план не жил вместе с системой. **Исправление:** scheduled game days, version control и action items после каждого теста.

## Когда применять

DR нужен каждому workload, потеря которого причиняет измеримый business impact. Масштаб различается: для низкой criticality достаточно воспроизводимой сборки, проверенного backup и ясного владельца; для критического пути нужны standby, fencing, capacity reservation и регулярная эвакуация площадки.

Design review считается завершённым, когда названы failure scenarios, business owner, RPO/RTO, dependencies, clean recovery mechanism, promotion/failback, runbook и свежий результат game day. Если recovery ещё ни разу не выполнялась, это гипотеза, а не capability.

## Источники

- [NIST SP 800-34 Rev. 1: Contingency Planning Guide for Federal Information Systems](https://nvlpubs.nist.gov/nistpubs/legacy/sp/nistspecialpublication800-34r1.pdf) — NIST, Rev. 1 Final, 2010, проверено 2026-07-18.
- [REL13-BP02 Use defined recovery strategies to meet the recovery objectives](https://docs.aws.amazon.com/wellarchitected/2022-03-31/framework/rel_planning_for_recovery_disaster_recovery.html) — Amazon Web Services, Well-Architected Framework, редакция 2022-03-31, проверено 2026-07-18.
- [REL09-BP04 Perform periodic recovery of the data to verify backup integrity and processes](https://docs.aws.amazon.com/wellarchitected/2022-03-31/framework/rel_backing_up_data_periodic_recovery_testing_data.html) — Amazon Web Services, Well-Architected Framework, редакция 2022-03-31, проверено 2026-07-18.
- [Disaster recovery planning guide](https://docs.cloud.google.com/architecture/dr-scenarios-planning-guide) — Google Cloud Architecture Center, last reviewed 2024-07-05, проверено 2026-07-18.
