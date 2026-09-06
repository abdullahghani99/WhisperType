"""Bounded, serialized model work; foreground requests precede queued background work.

Cancellation discards a queued result, but never lets a second operation access
the models while a cancelled native operation is still running.
"""
import asyncio
from concurrent.futures import Future
import itertools
import logging
import queue
import threading
import time


class InferenceBusy(Exception):
    pass


class InferenceWorker:
    def __init__(self, capacity=32):
        self._queue = queue.PriorityQueue(maxsize=capacity)
        self._sequence = itertools.count()
        self._thread = threading.Thread(target=self._run, daemon=True, name="inference")
        self._thread.start()

    async def submit(self, fn, *args, priority=0, **kwargs):
        future = Future()
        try:
            self._queue.put_nowait((priority, next(self._sequence), time.monotonic(),
                                   future, fn, args, kwargs))
        except queue.Full:
            raise InferenceBusy("Inference queue is full; retry shortly") from None
        return await asyncio.wrap_future(future)

    def _run(self):
        while True:
            _, _, queued, future, fn, args, kwargs = self._queue.get()
            try:
                if not future.set_running_or_notify_cancel():
                    continue
                started = time.monotonic()
                try:
                    result = fn(*args, **kwargs)
                except BaseException as error:
                    future.set_exception(error)
                else:
                    future.set_result(result)
                logging.getLogger("inference").info(
                    "%s queue_ms=%d run_ms=%d", getattr(fn, "__name__", "work"),
                    (started - queued) * 1000, (time.monotonic() - started) * 1000)
            finally:
                self._queue.task_done()
