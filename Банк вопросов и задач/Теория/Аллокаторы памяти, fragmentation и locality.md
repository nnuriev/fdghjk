---
aliases:
  - "Теоретический вопрос: Аллокаторы памяти, fragmentation и locality"
tags:
  - область/основы-cs
  - тема/память
  - тема/производительность
  - тип/вопрос
статус: проверено
---

# Аллокаторы памяти, fragmentation и locality

## Вопрос

Как allocator организует blocks и size classes, чем internal fragmentation отличается от external и почему освобождение объектов не обязано сразу уменьшать RSS?

## Короткий ориентир

Allocator обменивает точность размещения на скорость: группирует близкие размеры в size classes, хранит metadata, переиспользует free blocks и применяет arenas/local caches для снижения contention. Internal fragmentation — неиспользуемое место внутри выданного блока, external — свободная память, разбитая на неподходящие участки. `free` возвращает block allocator-у, но возврат страниц ОС зависит от layout, dirty pages и политики allocator; поэтому live bytes и RSS меняются независимо.

Полные механизмы, allocator API и задачи на fragmentation находятся в [[CurseHunter/6817/Бланк вопросов и заданий#Урок 17. Аллокаторы памяти|уроке 17]]. Связь с Go heap, GC и профилями раскрывают [[Банк вопросов и задач/Теория/Аллокации, GC и GC pressure|карточка аллокаций и GC]] и [[Банк вопросов и задач/Теория/Профилирование с pprof|pprof]].

## Варианты follow-up

- Почему `malloc(size)` осложняет in-place `free` без metadata?
- Когда per-thread/per-P cache снижает contention, но увеличивает memory footprint?
- Чем allocation-free hot path отличается от отсутствия всей memory-management стоимости?
- Почему одинаковые live bytes могут давать разный RSS и locality?

## Варианты формулировки и происхождение

- [[CurseHunter/6860/03 Дженерики, рефлексия и память#Allocator|Allocator]] — вопросы о lifetime assumptions, fragmentation, size classes, escape analysis, pools и arenas.
- [[CurseHunter/6609/09 Аллокатор#Урок 68. Size classes и уровни allocator|Урок 68. Size classes и уровни allocator]] — точная постановка вопроса о size classes в курсе 6609.
- [[CurseHunter/6817/Бланк вопросов и заданий#Урок 9. Устройство памяти Go и бенчмарки|Урок 9. Устройство памяти Go и бенчмарки]] — проверенный разбор allocation, layout, escape и benchmark boundary.
- [[CurseHunter/6817/Бланк вопросов и заданий#Урок 17. Аллокаторы памяти|Урок 17. Аллокаторы памяти]] — проверенный разбор fragmentation, arenas, caches, metadata и hardening.

- [[CurseHunter/6817/Бланк вопросов и заданий#1. Как Go выделяет малый объект и где участвуют `mcache`, `mcentral`, `mspan`, `mheap`?|1. Как Go выделяет малый объект и где участвуют `mcache`, `mcentral`, `mspan`, `mheap`?]] — точная формулировка вопроса курса 6817 из «Урок 9. Устройство памяти Go и бенчмарки».
- [[CurseHunter/6817/Бланк вопросов и заданий#2. Почему в Go `1.23.4` heap arena на Windows меньше?|2. Почему в Go `1.23.4` heap arena на Windows меньше?]] — точная формулировка вопроса курса 6817 из «Урок 9. Устройство памяти Go и бенчмарки».
- [[CurseHunter/6817/Бланк вопросов и заданий#1. Internal и external fragmentation: в чём разница|1. Internal и external fragmentation: в чём разница]] — точная формулировка вопроса курса 6817 из «Урок 17. Аллокаторы памяти».
- [[CurseHunter/6817/Бланк вопросов и заданий#2. Что происходит после `free`: live bytes не равны RSS|2. Что происходит после `free`: live bytes не равны RSS]] — точная формулировка вопроса курса 6817 из «Урок 17. Аллокаторы памяти».
- [[CurseHunter/6817/Бланк вопросов и заданий#3. Прямой вопрос: что не так с интерфейсом `malloc`/`free`/`realloc`|3. Прямой вопрос: что не так с интерфейсом `malloc`/`free`/`realloc`]] — точная формулировка вопроса курса 6817 из «Урок 17. Аллокаторы памяти».
- [[CurseHunter/6817/Бланк вопросов и заданий#5. Где хранить metadata и что даёт hardening|5. Где хранить metadata и что даёт hardening]] — точная формулировка вопроса курса 6817 из «Урок 17. Аллокаторы памяти».
- [[CurseHunter/6817/Бланк вопросов и заданий#7. Как объяснить путь jemalloc без лишних обещаний|7. Как объяснить путь jemalloc без лишних обещаний]] — точная формулировка вопроса курса 6817 из «Урок 17. Аллокаторы памяти».

## Источники

- [Go allocator: `malloc.go`](https://github.com/golang/go/blob/go1.23.4/src/runtime/malloc.go), [`mheap.go`](https://github.com/golang/go/blob/go1.23.4/src/runtime/mheap.go) и [`mgcscavenge.go`](https://github.com/golang/go/blob/go1.23.4/src/runtime/mgcscavenge.go) — Go repository, tag `go1.23.4`, проверено 2026-07-19.
- [`malloc(3)`](https://man7.org/linux/man-pages/man3/malloc.3.html), [`mmap(2)`/`munmap(2)`](https://man7.org/linux/man-pages/man2/mmap.2.html) и [`madvise(2)`](https://man7.org/linux/man-pages/man2/madvise.2.html) — Linux man-pages project, версия 6.18 от 2026-02-08; alignment, `realloc`, arenas glibc, mappings и `MADV_DONTNEED`/`MADV_FREE`, проверено 2026-07-19.
- [jemalloc manual](https://github.com/jemalloc/jemalloc/blob/5.3.0/doc/jemalloc.xml.in) — jemalloc repository, tag `5.3.0`; arenas, tcache, slabs/extents и decay/purge, проверено 2026-07-19.
