---
aliases:
  - Graceful shutdown
  - Draining backend service
tags:
  - область/бэкенд
  - тема/lifecycle
  - тема/надёжность
статус: проверено
---

# Graceful shutdown backend-сервиса

## TL;DR

Graceful shutdown переводит instance из serving в stopped без принятия новой работы, которую он уже не успеет завершить. Последовательность обычно такая: убрать instance из admission, перестать принимать запросы и задания, дождаться in-flight, остановить долгоживущие соединения, закрыть downstream resources и выйти. Весь процесс ограничен общим grace deadline, после которого нужен force stop.

Draining не гарантирует, что каждый запрос завершится: load balancer обновляется с задержкой, клиент может держать persistent connection, handler игнорирует cancellation, а процесс способен получить `SIGKILL`. Поэтому операции остаются идемпотентными, а queue workers подтверждают работу только после durable эффекта.

## Область применимости

- Контейнерный lifecycle соответствует Kubernetes 1.36.2. Default `terminationGracePeriodSeconds` равен 30 секундам.
- HTTP-пример соответствует `net/http.Server.Shutdown` из Go 1.26.5 и дополняет [[60 Go/Graceful shutdown|Go-специфичную заметку]].
- RPC-draining сверено с официальным gRPC Graceful Shutdown guide, изменённым 2025-01-15.
- Вне scope: graceful shutdown stateful database node, consensus member removal и миграция долгоживущей пользовательской сессии между processes.

## Ментальная модель

Shutdown — конечный автомат, а не обработчик сигнала с набором `Close()`:

```text
SERVING -> DRAINING -> STOPPING -> STOPPED
                      -> FORCED
```

В `DRAINING` новая работа больше не входит, а принятая получает шанс закончиться. В `STOPPING` отменяются остатки и закрываются зависимости. `FORCED` нужен, если общий срок истёк.

Порядок критичен. Если сначала закрыть DB pool, активные handlers упадут. Если сначала ждать handlers, но оставить listener открытым, новые requests не дадут счётчику обнулиться.

## Как устроено

### Снять instance с маршрутизации

Readiness должна стать false до завершения процесса. В Kubernetes terminating endpoint помечается в EndpointSlice: `ready=false`, а отдельное condition `serving` позволяет load balancer различать draining и полностью остановленный endpoint. Распространение состояния не мгновенно, поэтому приложение некоторое время ещё может получать трафик.

`preStop` иногда используют как короткий буфер на обновление routing. Он не добавляет штатного времени: hook выполняется внутри того же termination grace period. Если hook ещё работает при исчерпании срока, kubelet запрашивает одноразовое расширение на 2 секунды. Это аварийный запас, на который нельзя рассчитывать при расчёте budget. Слепой sleep без понимания задержек инфраструктуры просто съедает основное время.

### Прекратить admission

HTTP server закрывает listeners и idle connections, gRPC server прекращает принимать новые RPC, queue worker останавливает pull новых messages. Долгоживущие keep-alive connections требуют протокольного draining: в HTTP/2 для этого служит GOAWAY, в gRPC библиотека реализует свой graceful stop.

`net/http.Server.Shutdown(ctx)` закрывает listeners, затем idle connections и ждёт, пока active connections станут idle. Переданный `ctx` ограничивает ожидание, но не распространяется в handlers: при его истечении метод возвращает `ctx.Err()`, а active connections сам принудительно не закрывает. Приложение отдельно отменяет root/`BaseContext` для handlers и вызывает `Server.Close` либо свой force path, если budget исчерпан. `Shutdown` также не закрывает и не ждёт hijacked connections вроде WebSocket; их уведомляют и учитывают отдельно, например через `RegisterOnShutdown` и собственный registry.

### Дождаться in-flight в пределах общего срока

Handler получает [[20 Бэкенд/Дедлайны запросов и распространение отмены|deadline]], который не выходит за shutdown deadline. Это делает supervisor приложения через request/root context; `Server.Shutdown` сам такой deadline handler-у не добавляет. Новые длительные операции во время draining либо отклоняются, либо получают сокращённый budget. Background goroutines входят в тот же lifecycle через `WaitGroup`, errgroup или явный supervisor.

Для queue consumer порядок обычно такой: stop polling, завершить уже выданные messages, зафиксировать эффект, отправить ack. Если времени не хватило, delivery нужно вернуть broker или дать visibility lease истечь. Ack до завершения ради быстрого shutdown превращает остановку в потерю работы; связь с delivery guarantees раскрывает [[40 Распределённые системы/Очереди, streams, группы потребителей и DLQ|заметка о messaging]].

### Force и финальное закрытие

Когда in-flight закончились, закрывают pools, exporters и прочие shared resources, затем процесс выходит. Если deadline истёк, приложение отменяет оставшуюся работу и явно переходит к `Server.Close` или другому force path: один возврат `Shutdown` с ошибкой соединения не закроет. Это контролируемый отказ; без верхней границы rollout способен зависнуть навсегда.

Kubernetes сначала выполняет `preStop`, если он задан и grace period не нулевой, затем посылает TERM PID 1 контейнера. После истечения основного grace незавершённый hook может получить только одноразовое расширение на 2 секунды; затем оставшиеся процессы получают KILL. Порядок завершения обычных containers не следует считать гарантированным; специальные sidecar containers имеют отдельную lifecycle-семантику.

В Go есть тонкая ловушка: `Serve`/`ListenAndServe` после вызова `Shutdown` возвращает `ErrServerClosed`. Если main goroutine на этом сразу завершит процесс, ожидание Shutdown в другой goroutine оборвётся вместе со всеми handlers. Main должна дождаться завершения drain.

## Пример или трассировка

Pod имеет grace period 30 s. Самый длинный обычный HTTP request должен укладываться в 20 s.

1. В `t=0` начинается deletion. Endpoint помечается terminating и `ready=false`; параллельно запускается `preStop` на 3 s, выбранный по измеренной задержке routing.
2. В `t=3 s` PID 1 получает TERM. Приложение переводит state в DRAINING, закрывает listeners, отправляет сигнал WebSocket clients и прекращает брать новые queue messages.
3. HTTP/gRPC handlers и уже полученные messages продолжают работу. Shutdown context имеет deadline `t=28 s`, оставляя 2 s на force cleanup и exit.
4. В `t=25 s` последние обычные handlers завершились. Один WebSocket не закрылся; registry принудительно отменяет его в `t=28 s`.
5. Приложение закрывает DB/HTTP pools и exporters, main получает результат drain и выходит до `t=30 s`.

Если worker не успел обработать message, он не отправляет ack. Broker позже выдаст её снова, поэтому handler должен выдерживать redelivery.

## Trade-offs

Длинный grace period уменьшает число оборванных requests и redelivery, но замедляет deployment, node drain и аварийное удаление неисправного instance. Короткий быстрее освобождает capacity, зато чаще создаёт unknown outcomes.

Сначала readiness, затем drain — безопаснее для трафика. Но из-за eventual propagation всё равно нужен запас на поздние requests. Fixed `preStop sleep` прост, однако удлиняет каждый rollout даже при быстром обновлении маршрутов.

Ждать все connections нельзя для бесконечных streams. Им нужен отдельный протокол закрытия: уведомление, reconnect/resume token либо ограниченный max connection age.

## Типичные ошибки

### Main выходит раньше Shutdown

- **Неверное предположение:** `ListenAndServe` блокирует процесс до завершения active handlers.
- **Симптом:** connections обрываются сразу после TERM, хотя вызван `Shutdown`.
- **Причина:** server loop вернул `ErrServerClosed`, main завершился и остановил остальные goroutines.
- **Исправление:** main ждёт сигнал, запускает drain и не выходит до его результата или force deadline.

### Shared resources закрываются первыми

- **Неверное предположение:** закрытие pools поможет handlers быстрее закончить.
- **Симптом:** все in-flight requests одновременно получают DB/network errors.
- **Причина:** teardown нарушил dependency order.
- **Исправление:** stop admission, drain work, затем закрыть зависимости.

### `preStop` и приложение считают по 30 секунд каждый

- **Неверное предположение:** hook получает отдельный budget.
- **Симптом:** KILL приходит во время handler drain.
- **Причина:** `preStop` уже израсходовал часть общего grace period.
- **Исправление:** один абсолютный shutdown deadline, известный всем фазам.

### WebSocket считается обычным HTTP request

- **Неверное предположение:** `Server.Shutdown` дождётся hijacked connection.
- **Симптом:** rollout зависает внешне либо connection обрывается только при KILL.
- **Причина:** hijacked connections не управляются Shutdown.
- **Исправление:** registry, protocol-level close, собственный deadline и force path.

## Когда применять

Graceful shutdown нужен каждому process, который перезапускается, масштабируется или переносится между nodes. Даже stateless HTTP service имеет state в active requests, connections и buffers.

Перед rollout проверяют четыре сценария: поздний request после снятия readiness, длинный handler, зависший stream и TERM во время queue processing. Успех измеряют долей forced terminations, aborted requests, redeliveries и временем каждой shutdown phase.

## Источники

- [Pod Lifecycle: Termination of Pods](https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/#pod-termination) — Kubernetes, документация 1.36.2, проверено 2026-07-18.
- [Container Lifecycle Hooks](https://kubernetes.io/docs/concepts/containers/container-lifecycle-hooks/) — Kubernetes, документация 1.36.2, проверено 2026-07-18.
- [Graceful Shutdown](https://grpc.io/docs/guides/server-graceful-stop/) — gRPC Authors, commit страницы `cbe3d9a` от 2025-01-15, проверено 2026-07-18.
- [Server.Shutdown](https://pkg.go.dev/net/http@go1.26.5#Server.Shutdown) — Go project, Go 1.26.5, проверено 2026-07-18.
- [Server.Close](https://pkg.go.dev/net/http@go1.26.5#Server.Close) — Go project, Go 1.26.5, проверено 2026-07-18.
