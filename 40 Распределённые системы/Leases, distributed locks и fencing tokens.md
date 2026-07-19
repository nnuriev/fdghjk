---
aliases:
  - Leases, distributed locks и fencing tokens
  - Распределённые блокировки и fencing tokens
  - Lease и fencing token
tags:
  - область/распределённые-системы
  - тема/координация
  - механизм/ограждение
статус: проверено
---

# Leases, distributed locks и fencing tokens

## TL;DR

Distributed lock хранит решение о том, кому выдано право работать с ресурсом. Lease ограничивает это право сроком: после истечения authority может передать его другому владельцу, не дожидаясь пропавшего клиента. Но истёкший lease не останавливает процесс, не отменяет отправленный пакет и не стирает команду из очереди. Старый holder способен проснуться и выполнить работу одновременно с новым.

Fencing token закрывает этот разрыв. Каждая новая выдача exclusive-права получает монотонно растущее поколение. Holder передаёт token в защищаемую операцию, а сам ресурс атомарно отвергает поколение меньше уже увиденного. Lock service без такой проверки даёт координационное намерение, а не гарантированную mutual exclusion для внешнего side effect.

Lease, lock и fencing решают разные части задачи: lock сериализует выдачу права, lease освобождает его после недоступности holder, fencing лишает старую копию возможности действовать. Если ресурс не умеет проверять token, нужен иной барьер, вплоть до физического fencing узла.

## Область применимости

Основной сценарий — один writer или coordinator при crash-recovery, process pause и network partition. Byzantine-клиенты вне scope: holder соблюдает протокол, пока работает, но может потерять связь, надолго остановиться и возобновиться со старым состоянием. Модель lease опирается на Gray и Cheriton 1989 года, практический distributed lock и sequencer — на Chubby OSDI 2006.

## Ментальная модель

У права доступа есть три слоя:

```text
authority:  lock /foo выдан client B
validity:   lease действует до границы, известной authority
ordering:   fencing generation = 42
```

Lock отвечает «кому выдали». Lease отвечает «как долго issuer обязан уважать выдачу». Fencing token отвечает получателю операции: «эта команда новее команд прежних владельцев». Последний слой работает лишь у двери защищаемого ресурса. Номер, который никто там не проверяет, ничего не ограждает.

Полезный инвариант для exclusive writer: ресурс хранит `max_generation`; операция с `g < max_generation` не меняет состояние. Проверка и update `max_generation` выполняются атомарно с защищаемой записью либо до неё в том же serializable порядке.

## Как устроено

### Linearizable выдача права

Сначала нужен один авторитетный порядок acquire/release. Обычно lock service реплицирует своё состояние через [[40 Распределённые системы/Consensus на концептуальном уровне — Raft и Paxos|consensus]]. Иначе две partition могут независимо выдать один lock. Chubby cell обычно состоит из пяти реплик, master получает поддержку большинства, а записи подтверждаются после достижения большинства.

У lock есть identity и поколение. Acquire должен либо вернуть однозначное право, либо оставить клиенту неизвестный исход: timeout не сообщает, была ли выдача committed. Повтор acquire поэтому привязывают к session/request identity. `release` тоже не может означать «удалить любой lock по имени»; он освобождает только конкретную выдачу текущего holder.

Chubby делает locks advisory. Захват lock сам по себе не запрещает стороннему сервису изменить файл или БД. Это сознательная граница: защищаемые ресурсы часто живут в других системах.

### Lease и время

Lease — контракт, по которому issuer сохраняет права holder до ограниченного срока. В работе Gray и Cheriton server не может разрешить конфликтующую запись, пока все leaseholders не одобрят её либо их terms не истекут. После partition ограниченный срок даёт верхнюю границу ожидания, в отличие от бессрочного lock.

Clock uncertainty нельзя вычесть пожеланием. Server и client не обязаны видеть одну и ту же секунду; добавляются network delay и process pause. В исходной модели effective client term короче server term с поправкой на распространение сообщений, обработку и неопределённость часов. Практическое правило: issuer решает, когда старое право точно закончилось, а holder прекращает работу раньше своей консервативной границы. Перевод wall clock назад, восстановление authority без сохранённого lease state или выдача нового права до гарантированного истечения создают overlap.

Длинный lease уменьшает renewal traffic и переносит краткие сбои lock service. Он же задерживает failover. Короткий быстрее освобождается, но чаще renew-ится и легче теряется из-за latency spike. Автопродление снижает шум для приложения, однако callback «lease lost» не умеет прервать уже отправленную команду.

### Почему возникает stale holder

Процесс `A` захватил lock, затем остановился из-за длинной GC pause, scheduler suspension или заморозки VM. Его lease истёк. Lock service законно выдал право `B`. В этот момент `A` возобновляется: в памяти остались флаг `isLeader=true`, connection pool и подготовленный запрос. Никакого противоречия в lock service нет, но физически работают два процесса.

Проверка lease только внутри `A` ненадёжна: процесс мог остановиться между проверкой и side effect. Нужна проверка в системе, которая принимает side effect.

### Fencing token и Chubby sequencer

При каждом переходе exclusive lock из free в held authority увеличивает generation. Holder добавляет generation к write RPC. Получатель помнит максимальное поколение и отвергает старые запросы, даже если они пришли поздно.

Chubby называет такой объект sequencer. В нём есть имя lock, режим и lock generation number. Client передаёт sequencer file server или другому получателю, а тот проверяет validity и mode по Chubby либо сравнивает с наиболее свежим sequencer, который уже видел. В раннем примере статьи тот же принцип выражен acquisition count: file server отвергает write с меньшим count.

Random UUID не годится как fencing token: уникальность не задаёт порядок. Timestamp тоже рискован, если его выдаёт client с несогласованными часами. Номер должен исходить из сериализованной authority, монотонно расти в scope ресурса и переживать restart. Получатель обязан устойчиво хранить свой максимум; иначе после собственного crash он снова примет старое поколение.

Chubby также предлагает lock-delay для старых серверов, которые sequencer не проверяют: после потери holder lock некоторое время не выдаётся снова. Авторы прямо называют механизм imperfect. Delay снижает вероятность позднего запроса, но не доказывает, что запросов старше задержки не существует.

### Когда logical fencing невозможно

Не каждый ресурс умеет принять token: shared disk, legacy appliance или сторонний API могут не иметь такого поля. Тогда authority должна физически отрезать старого владельца от ресурса до старта нового. STONITH выключает или перезагружает узел; fabric fencing отзывает доступ к storage/network. Эта граница подробнее разобрана в [[40 Распределённые системы/Split brain|заметке о split brain]].

## Пример или трассировка

Lock `/jobs/month-close` защищает запись результата в storage. Каждая выдача получает generation.

1. Worker `A` получает lease и token `41`, начинает тяжёлый расчёт, затем процесс останавливается.
2. Lease `A` истекает. Authority выдаёт worker `B` token `42`.
3. `B` пишет результат с `g=42`. Storage атомарно устанавливает `max_generation=42` и сохраняет данные.
4. `A` просыпается и отправляет подготовленный ранее write с `g=41`.
5. Storage сравнивает `41 < 42`, отвергает запрос и не меняет данные.

Без шага 5 lock service всё сделал корректно, а итог всё равно зависел бы от порядка доставки. Если `A` успел выполнить внешний платёж до появления `42`, fencing не откатывает платёж. Для повторяемых эффектов дополнительно нужны operation ID и idempotency; для необратимых — протокол, в котором сторона эффекта участвует в проверке authority.

## Trade-offs

Бессрочный lock не зависит от clock bounds, но после потери holder требует ручного решения или надёжного failure oracle, которого в асинхронной сети нет. Lease автоматически возвращает доступность ценой временных предположений и renew traffic.

Coarse-grained lock редко захватывается и хорошо подходит для primary election. Fine-grained lock на каждую транзакцию превращает consensus service в горячий путь, увеличивает contention и создаёт крупный blast radius при его недоступности. Chubby проектировался именно для coarse-grained locking.

Logical fencing дешёв и адресен, если все получатели умеют сравнивать поколение. Physical fencing работает с legacy/shared resources, но медленнее, опаснее при ошибочной конфигурации и требует независимого control path.

## Типичные ошибки

- **Неверное предположение:** истёкший lease остановил holder. **Симптом:** старый worker пишет после failover. **Причина:** expiration изменил state authority, а не процесс и сеть. **Исправление:** проверять fencing token у ресурса.
- **Неверное предположение:** renewal thread доказывает владение в момент операции. **Симптом:** side effect проходит после долгой паузы. **Причина:** проверка и эффект разделены остановкой процесса. **Исправление:** переносить generation в сам запрос.
- **Неверное предположение:** любой уникальный token ограждает старого владельца. **Симптом:** получатель не знает, какой UUID новее. **Причина:** нет монотонного порядка. **Исправление:** выдавать durable generation из linearizable authority.
- **Неверное предположение:** Redis-подобный TTL или lock-delay заменяет fencing. **Симптом:** очень поздний пакет проходит после задержки. **Причина:** вероятность принята за инвариант. **Исправление:** downstream validation или physical isolation.
- **Неверное предположение:** release по имени безопасен после timeout. **Симптом:** старый client освобождает уже новую выдачу. **Причина:** release не связан с generation/session. **Исправление:** compare-and-release конкретного владения.

## Когда применять

Leases подходят для leader role, shard ownership, scheduler singleton и редкой координации, где автоматический failover важнее бесконечного ожидания. Для каждого lock фиксируют scope, authority и её consistency, lease/renewal bounds, durable generation, получателей token и реакцию на rejection.

Если защищаемая операция целиком живёт в consensus state machine, отдельный lock часто лишний: команда уже сериализуется журналом. Если все операции коммутируют или дедуплицируются, выгоднее убрать singleton owner. Если ресурс не умеет проверять generation, до автоматического failover нужен доказуемый physical fencing либо отказ от автоматического переключения.

## Источники

- [Leases: An Efficient Fault-Tolerant Mechanism for Distributed File Cache Consistency](https://www.cs.cmu.edu/afs/cs.cmu.edu/academic/class/15712-s12/www/papers/gray89.pdf) — Cary G. Gray, David R. Cheriton, SOSP 1989, проверено 2026-07-18.
- [The Chubby Lock Service for Loosely-Coupled Distributed Systems](https://research.google.com/archive/chubby-osdi06.pdf) — Google, OSDI 2006, проверено 2026-07-18.
- [In Search of an Understandable Consensus Algorithm](https://raft.github.io/raft.pdf) — Diego Ongaro, John Ousterhout, расширенная версия USENIX ATC 2014, проверено 2026-07-18.
- [Pacemaker Explained](https://clusterlabs.org/projects/pacemaker/doc/3.0/Pacemaker_Explained/pdf/Pacemaker_Explained.pdf) — ClusterLabs, Pacemaker 3.0.1, раздел Fencing, проверено 2026-07-18.
