---
aliases:
  - "Теоретический вопрос: TCP - handshake, надёжность и управление перегрузкой"
tags:
  - область/основы-cs
  - тема/сети
  - протокол/tcp
  - тип/вопрос
статус: проверено
---

# TCP - handshake, надёжность и управление перегрузкой

## Вопрос

Объясните тему «TCP - handshake, надёжность и управление перегрузкой»: как устроен механизм, какие инварианты определяют поведение и где проходят практические границы?

## Короткий ориентир

TCP создаёт между двумя sockets полнодуплексный упорядоченный поток байтов. Three-way handshake синхронизирует два независимых sequence spaces и параметры соединения. После этого sender хранит неподтверждённые bytes, receiver подтверждает следующий ожидаемый sequence number, дубли отбрасываются, а gaps закрываются retransmission.

Скорость ограничивают две разные обратные связи. Advertised receive window (`rwnd`) защищает buffer получателя, congestion window (`cwnd`) — общий network path. Грубо, sender держит в полёте не больше `min(rwnd, cwnd)`. Loss, retransmission timeout и Explicit Congestion Notification (ECN) относятся к congestion control; медленно читающее приложение меняет `rwnd`, но не доказывает congestion.

TCP гарантирует доставку байтов в socket stream либо сообщает transport failure. Он не знает, выполнил ли peer business operation. После timeout, FIN/RST или потерянного response результат request способен остаться неоднозначным.

Полный разбор: [[10 Основы CS/TCP - handshake, надёжность и управление перегрузкой|TCP - handshake, надёжность и управление перегрузкой]].

## Варианты follow-up

- Какие версионные границы меняют практический ответ?
- С какой ближайшей альтернативой сравнивается подход и по какому признаку выбирать?
- Какое неверное предположение приводит к наиболее опасному failure mode?

## Варианты формулировки и происхождение

- «TCP/UDP, путь запроса, DNS, TLS и HTTP: Модель TCP-IP и путь пакета, TCP - handshake, надёжность и управление перегрузкой, UDP, DNS resolution и caching, TLS handshake и проверка сертификатов, HTTP-1.1.» — [[Авито/roadmap#Сети, ОС и инфраструктура|Авито/roadmap, раздел «Сети, ОС и инфраструктура»]].

## Источники

- [RFC 9293: Transmission Control Protocol (TCP)](https://www.rfc-editor.org/rfc/rfc9293.html) — IETF, Internet Standard / RFC 9293, август 2022, проверено 2026-07-18.
- [RFC 5681: TCP Congestion Control](https://www.rfc-editor.org/rfc/rfc5681.html) — IETF, RFC 5681, сентябрь 2009, проверено 2026-07-18.
- [RFC 6298: Computing TCP's Retransmission Timer](https://www.rfc-editor.org/rfc/rfc6298.html) — IETF, RFC 6298, июнь 2011, проверено 2026-07-18.
- [RFC 7323: TCP Extensions for High Performance](https://www.rfc-editor.org/rfc/rfc7323.html) — IETF, RFC 7323, сентябрь 2014, проверено 2026-07-18.
- [RFC 2018: TCP Selective Acknowledgment Options](https://www.rfc-editor.org/rfc/rfc2018.html) — IETF, RFC 2018, октябрь 1996, проверено 2026-07-18.
- [RFC 3168: The Addition of Explicit Congestion Notification (ECN) to IP](https://www.rfc-editor.org/rfc/rfc3168.html) — IETF, RFC 3168, сентябрь 2001, проверено 2026-07-18.
