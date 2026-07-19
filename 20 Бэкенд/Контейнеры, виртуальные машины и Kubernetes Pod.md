---
aliases:
  - Containers, virtual machines and Kubernetes Pods
  - Контейнеры и виртуальные машины
  - Kubernetes Pod
tags:
  - область/бэкенд
  - тема/контейнеризация
  - тема/kubernetes
статус: проверено
---

# Контейнеры, виртуальные машины и Kubernetes Pod

## TL;DR

Процесс — исполняемая программа с адресным пространством и ресурсами ОС. Linux-контейнер не добавляет гостевое ядро: runtime запускает обычные процессы хоста с отдельными представлениями ресурсов через namespaces, ограничениями и учётом через cgroup v2, подготовленным root filesystem и дополнительными защитными политиками. Виртуальная машина (virtual machine, VM) виртуализирует аппаратную платформу и запускает собственное ядро, поэтому её граница изоляции тяжелее, но обычно сильнее.

Kubernetes Pod — не «ещё один контейнер» и не долговечный сервер. Это минимальная планируемая единица: один или несколько тесно связанных контейнеров совместно размещаются на одном node, делят сетевой контекст и явно подключённые volumes. Kubelet может перезапустить контейнер внутри прежнего Pod; controller при потере Pod создаёт замену с другим UID и, как правило, другим IP. Следствие: процесс и локальный writable layer считаются расходными, а долговечное состояние выносится за границу Pod.

## Область применимости

- Механика namespaces и cgroup v2 описана по upstream Linux 7.1 и Linux man-pages 6.18. Cgroup v1 и Windows containers имеют другой contract и здесь не разбираются.
- Kubernetes-утверждения относятся к версии 1.36.2, выпущенной 2026-06-09 и проверенной 2026-07-18.
- Формат образа сверён с OCI Image Specification 1.1.1, runtime contract — с OCI Runtime Specification 1.3.0.
- Вне scope: реализация конкретного runtime, overlay filesystem, service mesh, scheduler internals и полная модель безопасности Kubernetes.

## Ментальная модель

Полезно разделять четыре слоя:

```text
application process
        ↓
container: process + isolated views + resource policy + rootfs
        ↓
Pod: co-scheduling + shared network + declared shared volumes
        ↓
node / VM: kernel, CPU, memory, devices
```

[[10 Основы CS/Процесс, поток и goroutine|Процесс]] остаётся единицей, которую планирует ядро. Container — конфигурация запуска и изоляции одного или нескольких процессов. Pod группирует контейнеры, которые должны жить рядом. VM проводит границу ниже: внутри неё работает отдельная ОС со своим kernel.

## Как устроено

### Process, container и VM

Обычные процессы одного Linux host по умолчанию видят общую систему PID, mount points, network interfaces и другие глобальные объекты, хотя их виртуальная память разделена. Namespaces меняют именно представление: PID namespace даёт свой набор process IDs, mount — дерево mounts, network — interfaces, routes и ports, UTS — hostname, IPC — IPC-объекты, user namespace — отображение user/group IDs. Это не копии ядра: system calls всех контейнеров обслуживает kernel хоста.

Cgroup v2 решает другую задачу. Он иерархически группирует процессы, учитывает потребление и задаёт limits/weights для CPU, memory, PIDs и I/O. Namespace без cgroup может скрыть соседей, но не остановит процесс, который исчерпал общую память; cgroup без namespace ограничит ресурсы, но не создаст отдельный взгляд на систему.

Container boundary складывается из namespaces, cgroups, filesystem/mount configuration, Linux capabilities, seccomp и LSM-политик. Называть namespaces самостоятельной security boundary опасно: контейнеры разделяют ядро, а избыточные capabilities, privileged mode, host mounts или уязвимость kernel разрушают ожидаемую изоляцию.

VM получает virtual CPUs, memory и devices от hypervisor и загружает собственное ядро. Это увеличивает время запуска и memory overhead относительно процесса-контейнера, зато ошибка или компрометация guest kernel не равна прямому выполнению в kernel хоста. На практике контейнеры часто запускают внутри VM: эти слои решают разные задачи.

### Image и container instance

OCI image — переносимое, content-addressed описание: manifest ссылается на configuration и упорядоченные filesystem layers. Configuration задаёт параметры запуска, окружение и entrypoint. Image сам по себе — не запущенный процесс.

Runtime разворачивает layers в root filesystem, добавляет runtime configuration и запускает process. Получившийся container — instance конкретного image. Его writable layer не меняет исходный image и не должен считаться долговечным. Два контейнера из одного digest могут иметь разные environment, mounts, limits и состояние writable layer.

Практический инвариант supply chain: deploy должен ссылаться на проверяемый digest, а не полагаться только на изменяемый tag. Но digest подтверждает тождество bytes, а не их безопасность; нужны provenance, signature policy и scanning.

### Что именно объединяет Pod

Kubernetes совместно планирует все контейнеры Pod на один node. Они делят Pod IP и port space, поэтому связываются через `localhost` и обязаны не занимать один порт одновременно. Это не означает, что все namespaces всегда общие: например, общий process namespace включается отдельно через `shareProcessNamespace`.

Volume становится общим только для контейнеров, которым он смонтирован. `emptyDir` живёт столько же, сколько конкретный Pod: container crash его не удаляет, но удаление или замена Pod уничтожает данные. PersistentVolumeClaim задаёт storage с жизненным циклом вне конкретного Pod; его сохранность и доступность зависят от storage class и policy, а не от `restartPolicy`.

Pod удобен для тесно связанной пары application + sidecar, когда им нужны общий network identity, lifecycle и volume. Независимые сервисы не стоит помещать в один Pod: их нельзя раздельно масштабировать и размещать, а failure и rollout становятся связанными.

### Restart не равен replacement

У Pod есть стабильный UID в пределах его жизни. Если application container завершился, kubelet применяет `restartPolicy` и может создать новый container instance на том же node внутри того же Pod. Pod UID, network namespace и `emptyDir` сохраняются; process ID и содержимое container writable layer могут измениться.

Если node потерян, Pod удалён или Deployment меняет template, controller создаёт replacement Pod. Это новая сущность с новым UID; она может оказаться на другом node, получить другой IP и пустой `emptyDir`. Kubernetes не «переносит» прежний Pod между nodes.

Отсюда следует operational rule: readiness отвечает, можно ли направлять трафик на текущий instance, а liveness — способен ли локальный restart помочь. Ни одна probe не сохраняет in-memory state. Корректное завершение, дедлайны и снятие readiness раскрыты в [[20 Бэкенд/Graceful shutdown backend-сервиса|graceful shutdown backend-сервиса]].

## Пример или трассировка

Deployment держит две replicas API. В Pod `api-7f...` есть application container и sidecar, оба монтируют `emptyDir` для временных файлов.

1. Application process падает с ненулевым exit code. Kubelet перезапускает container согласно `restartPolicy: Always`.
2. Pod UID, его IP и `emptyDir` остаются прежними. In-memory cache процесса потерян, файл в `emptyDir` сохранился.
3. Затем node становится недоступен. Controller создаёт replacement Pod на другом node.
4. У replacement другой UID и IP, новый `emptyDir`; Service начинает направлять трафик после readiness. Данные, которые существовали только в прежнем `emptyDir`, потеряны.

Наблюдаемый результат объясняет два разных failure paths. «Контейнер перезапустился» может означать локальный restart внутри Pod; «приложение восстановилось» часто означает создание новой replica, а не оживление прежней машины.

## Trade-offs

- Container запускается и уплотняется легче VM, потому что не загружает отдельный guest kernel. VM даёт более самостоятельную kernel boundary ценой boot time, memory и управления образами ОС.
- Один container на Pod упрощает ownership и масштабирование. Sidecar оправдан, когда lifecycle и locality действительно общие; иначе он связывает rollout и ресурсы независимых компонентов.
- `emptyDir` быстр и удобен для scratch/cache. Persistent storage нужен для state, который должен пережить replacement, но добавляет attach, topology, backup и recovery constraints.
- Высокие resource limits уменьшают риск throttling/OOM текущего instance, но ухудшают density и blast radius. Низкие limits защищают node, однако требуют load test и наблюдения за throttling/working set.
- Immutable image digest делает rollout воспроизводимым. Mutable tag удобнее человеку, но один и тот же manifest может начать означать другие bytes.

## Типичные ошибки

- **Неверное предположение:** container — маленькая VM. **Симптом:** ожидают отдельный kernel, пытаются управлять им как полноценным host. **Причина:** container processes используют kernel node. **Исправление:** разделять process isolation и hardware virtualization.
- **Неверное предположение:** namespace автоматически ограничивает ресурсы. **Симптом:** один workload вызывает OOM или PID exhaustion на node. **Причина:** visibility isolation перепутана с cgroup accounting/limits. **Исправление:** задавать requests/limits, проверять cgroup metrics и admission policy.
- **Неверное предположение:** restart восстанавливает прежнее состояние. **Симптом:** после node failure исчезают локальные файлы и меняется адрес. **Причина:** replacement Pod — новая сущность. **Исправление:** externalize durable state, использовать Service/discovery и делать startup идемпотентным.
- **Неверное предположение:** volume всегда persistent. **Симптом:** `emptyDir` пережил container crash, но исчез при rollout. **Причина:** его lifetime связан с Pod UID. **Исправление:** выбирать volume type по требуемому lifecycle.
- **Неверное предположение:** несколько containers в Pod можно масштабировать независимо. **Симптом:** ради sidecar приходится увеличивать число тяжёлых application replicas. **Причина:** scheduler и controller оперируют целым Pod. **Исправление:** оставлять в Pod только действительно coupled components.

## Когда применять

Контейнер подходит, когда приложению нужен воспроизводимый пакет, process-level isolation и управляемые ресурсы. VM выбирают как более сильную инфраструктурную границу, для отдельного kernel/OS либо требований платформы. Kubernetes Pod нужен, когда workload должен планироваться, перезапускаться и масштабироваться controller-ом; при этом application проектируют как replica, готовую исчезнуть и быть заменённой.

На собеседовании полезно сначала назвать границу: «container изолирует процессы на общем kernel, VM виртуализирует машину, Pod группирует co-located containers». Затем разобрать, что переживает container restart, Pod replacement и node loss.

## Источники

- [Kubernetes 1.36](https://kubernetes.io/releases/1.36/) — Kubernetes, версия 1.36.2 от 2026-06-09, проверено 2026-07-18.
- [Pods](https://kubernetes.io/docs/concepts/workloads/pods/) — Kubernetes, документация ветки 1.36, проверено 2026-07-18.
- [Pod Lifecycle](https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/) — Kubernetes, документация ветки 1.36, проверено 2026-07-18.
- [Volumes](https://kubernetes.io/docs/concepts/storage/volumes/) — Kubernetes, документация ветки 1.36, проверено 2026-07-18.
- [OCI Image Format Specification](https://github.com/opencontainers/image-spec/tree/v1.1.1) — Open Container Initiative, tag `v1.1.1`, проверено 2026-07-18.
- [OCI Runtime Specification](https://github.com/opencontainers/runtime-spec/tree/v1.3.0) — Open Container Initiative, tag `v1.3.0`, проверено 2026-07-18.
- [Control Group v2](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/Documentation/admin-guide/cgroup-v2.rst?h=v7.1) — Linux kernel source documentation, tag `v7.1`, проверено 2026-07-18.
- [namespaces(7)](https://git.kernel.org/pub/scm/docs/man-pages/man-pages.git/tree/man/man7/namespaces.7?h=man-pages-6.18) — Linux man-pages project, tag `man-pages-6.18`, апрель 2026, проверено 2026-07-18.
