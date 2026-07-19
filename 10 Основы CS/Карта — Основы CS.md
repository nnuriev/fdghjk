---
aliases: []
tags:
  - тип/карта
  - область/основы-cs
статус: проверено
---

# Карта — Основы CS

## Назначение

Фундамент для рассуждений о сложности, ресурсах процесса, поведении операционной системы и передаче данных по сети.

## Входные знания

- Базовое владение любым языком программирования.
- Умение читать простой псевдокод и двоичное представление данных.

## Маршрут

- [[01 Маршруты/Backend — от основ к архитектуре|Backend — от основ к архитектуре]]

## Готовые заметки

### Operating Systems и Linux [Core]

- [[10 Основы CS/Процесс, поток и goroutine|Process vs thread vs goroutine.]]
- [[10 Основы CS/Планирование CPU и переключение контекста|Scheduling и context switching.]]
- [[10 Основы CS/User mode и kernel mode|User mode и kernel mode.]]
- [[10 Основы CS/Системные вызовы|System calls.]]
- [[10 Основы CS/Стек, heap и виртуальная память|Stack, heap, virtual memory.]]
- [[10 Основы CS/Paging и page faults|Paging и page faults.]]
- [[10 Основы CS/Примитивы синхронизации|Synchronization primitives.]]
- [[10 Основы CS/Атомики и memory ordering|Atomics и memory ordering.]]
- [[10 Основы CS/Файловые дескрипторы|File descriptors.]]
- [[10 Основы CS/Сокеты|Sockets.]]
- [[10 Основы CS/Блокирующий и неблокирующий ввод-вывод|Blocking и non-blocking I/O.]]
- [[10 Основы CS/select, poll, epoll и kqueue|select/poll/epoll/kqueue на концептуальном уровне.]]
- [[10 Основы CS/Файловая система и буферизация|Filesystem и buffering basics.]]
- [[10 Основы CS/Сигналы и graceful termination|Signals и graceful termination.]]
- [[10 Основы CS/Исчерпание ресурсов процесса|Resource exhaustion: memory, CPU, file descriptors, connections.]]

### Networking [Core]

- [[10 Основы CS/TCP - handshake, надёжность и управление перегрузкой|TCP: handshake, retransmission, ordering, flow control, congestion control.]]
- [[10 Основы CS/UDP|UDP.]]
- [[10 Основы CS/DNS resolution и caching|DNS resolution и caching.]]
- [[10 Основы CS/HTTP-1.1|HTTP/1.1.]]
- [[10 Основы CS/HTTP-2 и multiplexing|HTTP/2 multiplexing.]]
- [[10 Основы CS/HTTP-3 и QUIC|HTTP/3 и QUIC на концептуальном уровне.]]
- [[10 Основы CS/TLS handshake и проверка сертификатов|TLS handshake, certificates, certificate validation.]]
- [[10 Основы CS/Балансировка сетевой нагрузки|L4 vs L7 load balancing.]]
- [[10 Основы CS/Reverse proxy|Reverse proxy.]]
- [[10 Основы CS/IP, маршрутизация и NAT|NAT.]]
- [[20 Бэкенд/Пулы соединений и keep-alive|Keep-alive и connection pooling.]]
- [[10 Основы CS/Тайм-ауты на сетевых уровнях|Timeouts на каждом сетевом уровне.]]
- [[10 Основы CS/Retry safety|Retry safety.]]
- [[10 Основы CS/Proxy и service-to-service networking|Proxy и service-to-service networking.]]
- [[10 Основы CS/BGP и IS-IS|BGP/ISIS только для networking/infrastructure JD.]]

### Сетевой фундамент

- [[10 Основы CS/Модель TCP-IP и путь пакета|Модель TCP/IP и путь пакета.]]

## План заметок

### Coding Interview и алгоритмы [Core]

- [[10 Основы CS/Оценка временной и пространственной сложности|Оценка временной и пространственной сложности: worst/average/amortized.]]
- [[10 Основы CS/Массивы, строки, хеш-таблицы и множества|Arrays, strings, hash map/set.]]
- [[10 Основы CS/Связные списки, стек, очередь и двусторонняя очередь|Linked lists, stack, queue, deque.]]
- [[10 Основы CS/Деревья, BST, trie, кучи и приоритетные очереди|Trees, BST, trie, heap/priority queue.]]
- [[10 Основы CS/Графы и union-find|Graphs, union-find.]]
- [[10 Основы CS/Сортировка и бинарный поиск|Sorting, binary search.]]
- [[10 Основы CS/Two pointers и sliding window|Two pointers, sliding window.]]
- [[10 Основы CS/Префиксные суммы и difference arrays|Prefix sums, difference arrays.]]
- [[10 Основы CS/Интервалы|Intervals.]]
- [[10 Основы CS/Рекурсия и backtracking|Recursion, backtracking.]]
- [[10 Основы CS/BFS и DFS|BFS, DFS.]]
- [[10 Основы CS/Топологическая сортировка|Topological sort.]]
- [[10 Основы CS/Кратчайшие пути|Shortest paths.]]
- [[10 Основы CS/Жадные алгоритмы|Greedy algorithms.]]
- [[10 Основы CS/Динамическое программирование|Dynamic programming: 1D, 2D, subsequences, knapsack-style.]]
- [[10 Основы CS/Битовые операции и базовая математика|Bit manipulation и базовая математика.]]
- [[10 Основы CS/От brute force к оптимальному решению|Поиск brute-force решения и последовательная оптимизация.]]
- [[10 Основы CS/Доказательство корректности алгоритма|Доказательство корректности решения.]]
- [[10 Основы CS/Edge cases, невалидный ввод и overflow|Обработка edge cases, invalid input, overflow.]]
- [[10 Основы CS/Тестирование алгоритмических решений|Написание тестов до объявления решения завершённым.]]
- [[60 Go/Решение алгоритмической задачи на Go без IDE и autocomplete|Реализация компилируемого Go-кода без IDE и autocomplete.]]
- [[60 Go/Самостоятельная реализация структур данных и обходов графа в Go|Самостоятельная реализация heap, queue, stack, graph traversal в Go.]]
- [[10 Основы CS/Объяснение решения во время написания кода|Умение объяснять решение во время написания кода.]]

## Связанные карты

- [[20 Бэкенд/Карта — Бэкенд|Бэкенд]]
- [[40 Распределённые системы/Карта — Распределённые системы|Распределённые системы]]
- [[60 Go/Карта — Go|Go]]
