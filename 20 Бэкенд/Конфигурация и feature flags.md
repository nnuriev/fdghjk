---
aliases:
  - Configuration and feature flags
  - Feature toggles
  - Конфигурация приложения
tags:
  - область/бэкенд
  - тема/конфигурация
статус: проверено
---

# Конфигурация и feature flags

## TL;DR

Конфигурация задаёт параметры окружения для одного и того же артефакта: адреса зависимостей, limits, timeouts и режимы интеграции. Feature flag выбирает ветку поведения во время исполнения, иногда по evaluation context конкретного запроса. Это разные контракты: невалидная обязательная конфигурация должна остановить startup, а недоступность flag provider требует заранее выбранного default или последнего корректного snapshot.

Изменение конфигурации и флага — production change. Нужны типизированная схема, атомарное применение целого snapshot, безопасные defaults, аудит, наблюдаемая версия и rollback. Флаг без владельца и даты удаления становится постоянной альтернативной архитектурой; секрет, помещённый в flag context или ConfigMap, становится утечкой.

## Область применимости

Заметка охватывает server-side конфигурацию и runtime feature flags. В качестве конкретных контрактов используются Kubernetes ConfigMap v1.36 и OpenFeature specification на фиксированной ревизии `7886c6af69a2e77c16c84890bcfb02381e1163cf`, которая была upstream HEAD 2026-07-18. Управление секретами, PKI и реализация отдельного control plane остаются вне scope.

## Ментальная модель

Полезно разделять четыре типа изменяемых данных:

| Тип | Пример | Когда читается | Поведение при отсутствии |
|---|---|---|---|
| обязательная deploy config | DSN, listen address | startup | fail fast |
| динамическая operational config | pool limit, timeout | startup или reload | последний валидный snapshot |
| feature flag | `new_checkout` | на запрос/операцию | документированный default |
| secret | credential, private key | startup/reload через secret store | fail closed, не логировать |

Feature flag не обязан быть boolean. Он может вернуть строковый или числовой variant, но чем больше через него передаётся общей конфигурации, тем слабее его жизненный цикл как временного решения. Config отвечает «в каком окружении и с какими пределами работает процесс?», flag — «какой вариант поведения разрешён этому контексту при evaluation?».

## Как это устроено

### Конфигурационный pipeline

Надёжная загрузка выглядит как единая транзакция над памятью процесса:

```text
sources -> parse -> normalize -> validate cross-field invariants
        -> build immutable snapshot -> atomic publish -> observe version
```

Приоритет источников задают один раз, например defaults < file < environment < explicit runtime override. Неявное смешивание делает поведение невоспроизводимым. Значения преобразуют в типы и единицы на границе: `REQUEST_TIMEOUT=2s` становится duration, а не строкой, которую каждый caller трактует отдельно.

Cross-field validation проверяет причинные ограничения: request deadline должен быть больше downstream timeout плюс резерв; minimum pool не превышает maximum; включённая интеграция имеет endpoint и credential. При ошибке startup завершается до приёма трафика. Для reload новый snapshot полностью валидируют до атомарной замены; частично обновлённые поля могут нарушить инвариант между ними.

Не все параметры можно безопасно менять на лету. Listen address, формат хранилища или алгоритм шардирования часто требуют restart/migration. Поддерживать reload стоит только там, где компонент умеет перестроить ресурсы и завершить использование старого snapshot.

### Хранение и доставка config

Twelve-Factor App рекомендует отделять config, меняющуюся между deploys, от кода и передавать её через environment variables. Это полезная исходная модель, но не универсальный механизм: env процесса не меняется атомарно во время runtime и плохо подходит для больших структурированных документов.

Kubernetes ConfigMap хранит нечувствительные пары ключ-значение и может быть передан как env или смонтированный файл. Обновление файла и env имеет разный жизненный цикл; приложение не должно предполагать мгновенный reload. Immutable ConfigMap запрещает изменение данных и заставляет создать новый объект, что делает rollout воспроизводимее. ConfigMap не предоставляет secrecy: credential должен идти через предназначенный для секретов канал и всё равно не попадать в логи.

### Feature flag evaluation

По OpenFeature evaluation принимает `flag key`, ожидаемый тип, caller-supplied default и evaluation context. Context может включать стабильный targeting key, tenant, регион или план. Detailed evaluation может показать variant и reason, если provider их задал; контракт не обещает присутствие этих metadata для каждого решения. Нельзя передавать туда bearer token, email без необходимости или иные чувствительные данные только ради удобства targeting.

На практике стабильный percentage rollout вычисляют детерминированно из targeting key и flag key. Иначе один пользователь будет прыгать между variants на каждом запросе, а сравнение результатов потеряет смысл. Для связанных флагов нужна единица stickiness: user, account, device или request — это часть продуктового инварианта. Это правило проектирования provider/control plane; OpenFeature стандартизирует evaluation API, но не алгоритм bucketing или stickiness.

Fallback определяют по риску:

- новый необязательный UI/алгоритм обычно безопасно выключить;
- защитную проверку нельзя «fail open» только потому, что provider недоступен;
- последний подписанный/валидный snapshot уменьшает outage, но делает решение stale.

OpenFeature no-op provider возвращает caller-supplied default. Значит, default — не декоративное значение SDK, а реальное поведение при отсутствии provider.

### Жизненный цикл флага

Для каждого флага фиксируют owner, назначение, безопасный default, дату/условие удаления и метрики по variants. Rollout проходит ступенями, но процент сам по себе не защищает: сначала нужен ограниченный blast radius, затем сравнение ошибок, latency и бизнес-результата.

После окончательного решения удаляют losing branch, evaluation и control-plane entry. Иначе комбинации флагов растут экспоненциально, тесты проверяют лишь малую долю состояний, а старый код продолжает определять data schema и security surface.

## Сквозной пример: rollout нового checkout

Один и тот же артефакт получает startup config:

```text
PAYMENTS_ENDPOINT=https://payments.internal
PAYMENTS_TIMEOUT=800ms
```

и flag `new_checkout`, default `false`.

1. На startup приложение парсит timeout, проверяет наличие endpoint и credential. При `PAYMENTS_TIMEOUT=unknown` процесс не становится ready.
2. Для запроса account `a42` evaluation context содержит targeting key `account:a42`, tenant plan и region, но не access token.
3. В этом примере provider/control plane настроен детерминированно относить `a42` к variant `new`. Все запросы этого account получают одну ветку, пока правило не изменено; это свойство выбранной реализации, а не гарантия OpenFeature.
4. У новой ветки растёт доля payment timeout. Оператор возвращает flag в `false`; новые запросы идут по старой ветке без выпуска бинарника.
5. В этом deployment provider использует локальный последний валидный snapshot до заданного TTL. Если evaluation завершается abnormal result, OpenFeature возвращает caller-supplied default `false`; snapshot cache и его TTL остаются политикой provider, а не спецификации. В логах и метриках видны flag key, доступные variant/reason и версия config, но нет персональных данных.

Наблюдаемый результат: config validation защищает процесс от некорректного окружения, а flag уменьшает blast radius поведенческого изменения. Ни один механизм не отменяет совместимость данных: если новая ветка уже записала новый формат, rollback кода должен уметь его читать.

## Trade-offs и альтернативы

### Deploy или feature flag

Обычный deploy проще, если изменение можно выпустить атомарно и быстро откатить без риска данных. Flag полезен для постепенного rollout, kill switch и разделения deploy от release, но создаёт две ветки и удалённую зависимость. Не каждое условие заслуживает control plane.

### Startup-only или dynamic reload

Startup config даёт один воспроизводимый snapshot на жизнь процесса и простой rollback через rollout. Dynamic reload быстрее меняет limits, но требует атомарности, versioning и поведения существующих операций. Если компонент не умеет согласованно применить параметр, restart честнее скрытого частичного reload.

### Централизованный provider или локальный snapshot

Центральный provider даёт targeting и быстрый аудит, но находится на request path логически, даже если SDK кэширует данные. Локальный versioned snapshot устойчивее и воспроизводимее, зато медленнее распространяется. Гибрид использует control plane для доставки, а evaluation выполняет локально по последнему проверенному snapshot.

## Типичные ошибки

### Default без анализа риска

- **Неверное предположение:** `false` всегда безопасен.
- **Симптом:** outage provider отключает обязательную security check или записывает несовместимые данные.
- **Причина:** default выбран по типу флага, а не по инварианту.
- **Исправление:** документировать fail-open/fail-closed для каждого флага и проверять rollback данных.

### Частичный reload

- **Неверное предположение:** поля config независимы.
- **Симптом:** новый timeout используется со старым capacity limit, система перегружается.
- **Причина:** watchers обновляют mutable globals по одному.
- **Исправление:** собрать и валидировать immutable snapshot, затем заменить его атомарно.

### Вечный feature flag

- **Неверное предположение:** условие почти ничего не стоит.
- **Симптом:** неизвестно, какие комбинации работают, старую ветку нельзя удалить.
- **Причина:** нет owner и exit criteria.
- **Исправление:** lifecycle metadata, регулярный cleanup и удаление кода после решения.

### ConfigMap как secret store

- **Неверное предположение:** объект кластера автоматически конфиденциален.
- **Симптом:** credential виден через API, debug dump или repository manifest.
- **Причина:** ConfigMap предназначен для config data, а не секретности.
- **Исправление:** отдельный secret mechanism, минимальные права и запрет логирования значений.

## Когда применять

Deploy config нужна любому процессу, который должен запускать один артефакт в разных окружениях. Dynamic config оправдана для параметров, которые нужно менять быстрее rollout и которые компонент умеет применить атомарно. Feature flag нужен для ограниченного rollout, kill switch, experiment или временного разделения deploy/release.

Перед добавлением параметра определяют его owner, тип, диапазон, источник, момент применения, fallback, наблюдаемую версию и способ удаления. Если неизвестно, что произойдёт при потере control plane, контракт ещё не завершён.

## Источники

- [The Twelve-Factor App: Config](https://www.12factor.net/config) — Adam Wiggins, редакция 2017 года, проверено 2026-07-18.
- [ConfigMaps](https://kubernetes.io/docs/concepts/configuration/configmap/) — Kubernetes, документация v1.36, проверено 2026-07-18.
- [ConfigMap v1 API](https://kubernetes.io/docs/reference/kubernetes-api/core/config-map-v1/) — Kubernetes, API `core/v1` v1.36, проверено 2026-07-18.
- [OpenFeature Specification](https://github.com/open-feature/spec/tree/7886c6af69a2e77c16c84890bcfb02381e1163cf/specification) — OpenFeature, commit `7886c6af69a2e77c16c84890bcfb02381e1163cf`, проверено 2026-07-18.
- [Evaluation Context](https://github.com/open-feature/spec/blob/7886c6af69a2e77c16c84890bcfb02381e1163cf/specification/sections/03-evaluation-context.md) — OpenFeature, commit `7886c6af69a2e77c16c84890bcfb02381e1163cf`, проверено 2026-07-18.
- [Flag Evaluation API](https://github.com/open-feature/spec/blob/7886c6af69a2e77c16c84890bcfb02381e1163cf/specification/sections/01-flag-evaluation.md) — OpenFeature, commit `7886c6af69a2e77c16c84890bcfb02381e1163cf`, проверено 2026-07-18.
