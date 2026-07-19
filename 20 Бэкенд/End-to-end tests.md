---
aliases:
  - End-to-end testing
  - E2E tests
  - Сквозные тесты
tags:
  - область/бэкенд
  - тема/тестирование
статус: проверено
---

# End-to-end tests

## TL;DR

End-to-end test (E2E) проверяет пользовательски значимый путь через собранную систему: действие входит через публичную границу, проходит все компоненты внутри объявленного SUT и наблюдается как конечный внешний outcome. Его сила — wiring, configuration и взаимодействие нескольких процессов; его цена — медленный feedback, больше причин отказа и сложная диагностика.

«End» всегда нужно назвать. E2E сервиса может включать API, PostgreSQL, broker и worker, но заканчивать путь на sandbox платёжного provider. Это полноценный E2E для объявленного SUT, но не доказательство интеграции с production provider. Скрытая подмена превращает широкий тест в ложную уверенность.

## Область применимости

Заметка относится прежде всего к backend API и asynchronous workflows. UI/browser может быть начальной границей, но не обязателен: API client, CLI или message ingress тоже выражают пользовательский путь.

E2E в изолированной среде отличается от production probe. Первый проверяет известный сценарий на versioned assembly; второй наблюдает уже развернутую, негерметичную конфигурацию и должен быть безопасен для реальных данных и side effects.

## Ментальная модель

E2E — это проверка композиции:

```text
public input -> routing/auth -> service -> storage/broker -> worker
             -> externally observable final outcome
```

Unit tests доказывают локальные решения, integration tests — выбранные protocol seams, contract tests — совместимость версий. E2E отвечает на оставшийся вопрос: собраны ли эти корректные части в работающий путь с реальными configuration, migrations, credentials, routing и lifecycle.

Поэтому E2E не должен заново перебирать все business cases. Один critical journey подтверждает composition, а combinatorial input space остаётся на дешёвых уровнях.

## Как устроено

### Объявить SUT и manifest

Test artifact фиксирует:

- входную и конечную публичные границы;
- какие services, datastores, brokers и migrations реальны;
- какие third parties заменены sandbox/fake и почему;
- versions/images/configuration каждого участника;
- seed data, tenant и feature flags;
- deadline и критерий завершения;
- диагностические artifacts при failure.

Название «E2E» без такого manifest не даёт понять, какое доказательство получено.

### Выбирать journeys по риску

Минимальный suite обычно содержит:

- один smoke path на критическую ценность;
- один значимый отказ или deny path;
- один asynchronous/retry path, если он является частью архитектуры;
- regression journey только для дефекта, который действительно возник из composition.

Вариации validation, calculations и permissions лучше проверять ниже. Google рекомендует держать число E2E tests небольшим и связывать их с важными use cases и classes of error, потому что стоимость стабилизации заметно выше, чем у узких tests.

### Изолировать состояние

Каждый case получает уникальный tenant/account/key либо чистый ephemeral environment. Setup выполняется через поддерживаемый public/admin API или versioned fixture mechanism; зависимость от порядка tests запрещена. Cleanup не должен скрывать failure, поэтому identifiers и состояние сохраняют до сбора artifacts.

Shared staging повышает topology fidelity, но делает fixture зависимой от чужих deploy и данных. Такой signal полезен как release test, но не должен быть единственным merge gate.

### Ждать состояние, а не время

Для asynchronous path test после команды опрашивает публичный status либо ждёт предметное событие до bounded deadline. `sleep(5s)` одновременно слишком короток на медленном CI и зря тормозит быстрый run. Polling обязан завершаться по terminal success/failure и логировать последний наблюдаемый state.

Общий deadline представляет обещание journey, а не сумму произвольных sleeps. Правила распространения cancellation и различие между timeout и commit раскрыты в [[20 Бэкенд/Дедлайны запросов и распространение отмены|заметке о дедлайнах]].

### Проверять outcome, а не внутреннюю топологию

Assertions читают response, публичный query, emitted callback/message у test-owned boundary или иной пользовательски видимый effect. Проверка внутренних table names, числа RPC hops и порядка private workers делает test хрупким и дублирует integration suites.

При failure нужны correlation/request ID, versions/config hash, service logs, distributed trace, последние public states и данные controllable fakes. Повторный запуск не заменяет эти artifacts: flaky E2E особенно дорог, потому что без следа корневая причина теряется между компонентами.

### Разделить hermetic E2E и production checks

Hermetic servers и локальные controllable dependencies позволяют собирать весь SUT без внешней сети. Это повышает воспроизводимость, но dataset и topology могут отличаться от production. Staging/release test добавляет deployment fidelity. Safe synthetic probe после rollout проверяет ещё одну конфигурацию, однако не должен создавать необратимые side effects или зависеть от «последней» source configuration, отличной от deployed version.

## Пример или трассировка

Проверяется journey оформления заказа. SUT включает gateway, order service, PostgreSQL, broker и worker. Платёжная система заменена stateful sandbox; email delivery вне scope. Вход и итог наблюдаются через public API.

1. Test создаёт уникального customer и product со stock `5`, затем отправляет `POST /orders` с quantity `2` и `Idempotency-Key: e2e-734`.
2. API возвращает `202` и `order_id=o-91`.
3. Worker получает событие, вызывает payment sandbox и завершает reservation.
4. Test опрашивает `GET /orders/o-91` до bounded deadline. Terminal outcome должен быть `confirmed`, quantity `2`, total в ожидаемой currency.
5. Повтор исходного `POST` с тем же key возвращает тот же `o-91`; payment sandbox показывает одну authorization, а public stock endpoint — `3`.

Наблюдаемая цепочка доказывает routing, migrations, transaction/outbox wiring, broker delivery в этом сценарии, worker startup, public status и [[20 Бэкенд/Ключи идемпотентности и дедупликация запросов|idempotency]] собранного пути. Она не доказывает реальный payment network, все redelivery histories, нагрузочную capacity или каждую формулу total — эти риски требуют отдельных tests.

Если status застрял в `pending`, сохранённый trace должен показать последний успешный hop. Без него test сообщает только симптом «journey не завершился», а не различает missing outbox row, неверный broker route и остановленный worker.

## Trade-offs

Полностью hermetic environment воспроизводим и безопасен для merge gate, но требует поддерживать fakes и может расходиться с production topology. Shared staging ближе к deployment, зато содержит конкурирующие releases, quotas и загрязнённые данные. Обычно нужны оба сигнала с разной ролью: hermetic E2E блокирует очевидный composition defect, staging/canary проверяет deployment-specific risk.

Black-box assertions переживают refactoring, но дают слабую локализацию. Дополнительные logs/traces улучшают диагностику, не превращая внутренние детали в pass/fail contract.

Широкий suite увеличивает scenario fidelity, но каждая новая комбинация умножает runtime и flake surface. Дешевле один E2E на journey плюс dense unit/integration coverage каждой развилки, чем полный декартов product на верхнем уровне.

## Типичные ошибки

- **Неверное предположение:** E2E означает все реальные внешние системы. **Симптом:** CI зависит от production-like third party, создаёт side effects или случайно падает. **Причина:** SUT boundary не объявлена. **Исправление:** явно назвать ends, использовать supported sandbox/controllable boundary и отдельно проверять real-provider contract.
- **Неверное предположение:** больше E2E автоматически даёт больше уверенности. **Симптом:** долгий flaky pipeline и дублирующие cases. **Причина:** decision space поднят на самую дорогую границу. **Исправление:** оставить critical journeys, варианты перенести в unit/integration/contract suites.
- **Неверное предположение:** fixed sleep синхронизирует workflow. **Симптом:** test медленный локально и нестабилен в CI. **Причина:** время не является completion signal. **Исправление:** bounded polling/event с terminal state и общим deadline.
- **Неверное предположение:** retry до pass устраняет flake. **Симптом:** release проходит после повторов без понятной причины первого отказа. **Причина:** instability скрыта policy runner. **Исправление:** первый failure сохранять, retry маркировать flaky и собирать trace/state before cleanup.
- **Неверное предположение:** staging всегда представляет release. **Симптом:** test проверяет другую версию config или соседний незавершённый deploy. **Причина:** environment не versioned и не принадлежит run. **Исправление:** manifest artifacts/config, изолированный cohort и проверка фактически deployed versions.
- **Неверное предположение:** внутренние DB assertions делают E2E точнее. **Симптом:** безопасная смена schema ломает journey test. **Причина:** implementation detail стал внешним oracle. **Исправление:** проверять public outcome; DB schema оставить repository integration suite.

## Когда применять

E2E нужен для нескольких путей, где ценность возникает только из композиции: регистрация с подтверждением, заказ с asynchronous processing, auth flow, migration/startup и критический rollback/retry journey. Его запускают на собранном release artifact, а не на случайной смеси локальных binaries.

При rollout E2E signal дополняют проверками из [[50 Проектирование систем/Миграция и rollout без остановки|стратегии безопасной миграции]]: coexistence старых и новых versions, readiness, canary и rollback нельзя доказать одним pre-deploy journey.

## Источники

- [Testing for Reliability](https://sre.google/sre-book/testing-reliability/) — Google, Site Reliability Engineering, глава 17, system tests, release tests и production probes, проверено 2026-07-18.
- [Hermetic Servers](https://testing.googleblog.com/2012/10/hermetic-servers.html) — Google Testing Blog, 2012, end-to-end server stack и hermetic environment, проверено 2026-07-18.
- [What Makes a Good End-to-End Test?](https://testing.googleblog.com/2016/09/testing-on-toilet-what-makes-good-end.html) — Google Testing Blog, 2016, выбор journeys, state isolation и diagnostic artifacts, проверено 2026-07-18.
- [Just Say No to More End-to-End Tests](https://testing.googleblog.com/2015/04/just-say-no-to-more-end-to-end-tests.html) — Google Testing Blog, 2015, feedback, flakiness и failure localization, проверено 2026-07-18.
- [Where do our flaky tests come from?](https://testing.googleblog.com/2017/04/where-do-our-flaky-tests-come-from.html) — Google Testing Blog, 2017, связь размера tests и flakiness, проверено 2026-07-18.

