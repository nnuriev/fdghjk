---
aliases:
  - "Теоретический вопрос: Protobuf, XML и SOAP"
tags:
  - область/бэкенд
  - тема/сериализация
  - тип/вопрос
статус: черновик
---

# Protobuf, XML и SOAP

## Вопрос

Как различаются Protobuf, XML и SOAP по контракту данных, эволюции схемы и модели обработки сообщений?

## Короткий ориентир

Protobuf задаёт schema-driven binary messages и правила совместимости полей; gRPC может использовать его как IDL и message format, но это разные уровни. XML задаёт текстовое дерево, а SOAP поверх XML определяет envelope, optional header, mandatory body и fault processing model.

Полные разборы:

- [[Telegram Собесы/APM Group — 2026-03-16 — 3150 USD/Бланк вопросов и заданий#Protobuf versions|APM Group: Protobuf versions]]
- [[Telegram Собесы/APM Group — 2026-03-16 — 3150 USD/Бланк вопросов и заданий#XML и SOAP — `00:18:34–00:20:43`|APM Group: XML и SOAP]]

## Варианты follow-up

- Какие schema changes Protobuf остаются wire-compatible?
- Когда нужен streaming `xml.Decoder.Token`, а не чтение всего документа?
- Что содержат SOAP `Envelope`, optional `Header`, mandatory `Body` и `Fault`?

## Варианты формулировки и происхождение

- [[Telegram Собесы/APM Group — 2026-03-16 — 3150 USD/Бланк вопросов и заданий#Transports, gRPC и Protobuf — `00:14:42–00:17:02`|APM Group, Protobuf]].
- [[Telegram Собесы/APM Group — 2026-03-16 — 3150 USD/Бланк вопросов и заданий#XML и SOAP — `00:18:34–00:20:43`|APM Group, XML и SOAP]].

## Источники

- [Protobuf Version Support](https://protobuf.dev/support/version-support/) — Protocol Buffers project, supported proto2/proto3/Editions и различие syntax/release versions; проверено `2026-07-18`.
- [Protobuf Editions Overview](https://protobuf.dev/editions/overview/) — Protocol Buffers project, Editions 2023/2024 и evolution model; проверено `2026-07-18`.
- [Proto2 Language Guide](https://protobuf.dev/programming-guides/proto2/) — Protocol Buffers project, proto2 compatibility, extensions и рекомендация для новых gRPC services; проверено `2026-07-18`.
- [Package encoding/xml](https://pkg.go.dev/encoding/xml@go1.26.5) — Go standard library `go1.26.5`, marshal/unmarshal, struct tags и streaming decoder; проверено `2026-07-18`.
- [SOAP Version 1.2 Part 1](https://www.w3.org/TR/soap12-part1/) — W3C Recommendation, envelope, header, body, processing model и faults; проверено `2026-07-18`.
