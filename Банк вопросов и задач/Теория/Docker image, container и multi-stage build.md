---
aliases:
  - "Теоретический вопрос: Docker image, container и multi-stage build"
tags:
  - область/бэкенд
  - тема/контейнеризация
  - тип/вопрос
статус: проверено
---

# Docker image, container и multi-stage build

## Вопрос

Чем Docker image отличается от container и как собрать Go binary внутри Docker, не перенося compiler и исходники в runtime image?

## Короткий ориентир

Image задаёт filesystem и конфигурацию, из которых запускается container; container добавляет выполняющийся process и изменяемое runtime-состояние. В multi-stage build первый stage содержит Go toolchain, modules и исходники, а финальный получает через `COPY --from` только binary и действительно нужные runtime files.

`FROM scratch` допустим, но подходит не каждому binary. HTTPS может потребовать CA bundle, операции с часовыми поясами — timezone database, а CGO-linked binary — dynamic libraries. Поэтому `scratch`, distroless и более полный runtime image выбирают по зависимостям и operating model, а не только по размеру.

Полный проверенный разбор: [[Telegram Собесы/MERLION — 2025-07-29 — 300к/Бланк вопросов и заданий#3. Docker: `scratch` — специальный пустой base|multi-stage build и границы `scratch`]]. Базовая граница container и virtual machine раскрыта в [[Банк вопросов и задач/Теория/Контейнеры, виртуальные машины и Kubernetes Pod|вопросе о контейнерах, VM и Pod]].

## Варианты follow-up

- Когда статический Go binary действительно запустится в `scratch`?
- Какие runtime dependencies добавляют CGO, HTTPS и timezone operations?
- Когда distroless удобнее `scratch`, несмотря на больший image?

## Варианты формулировки и происхождение

- «Нужно собрать Go binary внутри Docker, но не переносить compiler и исходники в runtime image. Как это сделать?» — [[Telegram Собесы/MERLION — 2025-07-29 — 300к/Бланк вопросов и заданий#Docker image, container и multi-stage build — `00:22:21–00:26:46`|MERLION, Docker image, container и multi-stage build]].

## Источники

- [Multi-stage builds](https://docs.docker.com/build/building/multi-stage/) — Docker, current documentation, проверено 2026-07-19.
