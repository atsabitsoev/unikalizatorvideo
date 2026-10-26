#!/usr/bin/env python3
"""Проверка уникальности копий по PDQ — открытому алгоритму Meta для поиска дубликатов.

Для каждого кадра копии (2 кадра в секунду) ищется самый похожий кадр оригинала.
Кадры считаются «одинаковыми», если расстояние Хэмминга между PDQ-хешами <= 31
(порог, который рекомендует Meta). По тому же принципу работает их видеосопоставитель
vPDQ: видео считается копией, если совпало большинство кадров (обычно 80% и больше).

Установка зависимостей:  pip3 install numpy pdqhash
Запуск:                  python3 tools/check_uniqueness.py оригинал.mp4 оригинал_uniq_*.mp4
"""
import subprocess
import sys

try:
    import numpy as np
    import pdqhash
except ImportError:
    sys.exit("Нужны пакеты numpy и pdqhash:  pip3 install numpy pdqhash")

FPS = 2
SIDE = 256  # PDQ всё равно сжимает кадр до 64x64
THRESHOLD = 31


def frame_hashes(path):
    cmd = ["ffmpeg", "-v", "error", "-i", path, "-vf",
           f"fps={FPS},scale={SIDE}:{SIDE}:flags=area,format=rgb24", "-f", "rawvideo", "-"]
    raw = subprocess.run(cmd, capture_output=True, check=True).stdout
    size = SIDE * SIDE * 3
    frames = np.frombuffer(raw, np.uint8)[: len(raw) // size * size].reshape(-1, SIDE, SIDE, 3)
    return np.array([np.packbits(pdqhash.compute(np.ascontiguousarray(f))[0].astype(np.uint8)) for f in frames])


def nearest(a, b):
    """Для каждого кадра a — расстояние до ближайшего кадра b."""
    return np.unpackbits(np.bitwise_xor(a[:, None, :], b[None, :, :]), axis=2).sum(axis=2).min(axis=1)


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    orig, copies = sys.argv[1], sys.argv[2:]
    ho = frame_hashes(orig)
    hashes = {c: frame_hashes(c) for c in copies}

    print(f"{'файл':<40} {'совпало кадров':>15} {'среднее расстояние':>19}")
    for c in copies:
        d = nearest(hashes[c], ho)
        print(f"{c.split('/')[-1][:40]:<40} {100 * (d <= THRESHOLD).mean():>14.0f}% {d.mean():>19.0f}")

    if len(copies) > 1:
        pairs = [100 * (nearest(hashes[a], hashes[b]) <= THRESHOLD).mean()
                 for i, a in enumerate(copies) for b in copies[i + 1:]]
        print(f"\nКопии между собой: совпадение кадров в среднем {np.mean(pairs):.0f}%, "
              f"у самой похожей пары {max(pairs):.0f}%")
    print(f"\nСовпадение кадров с оригиналом 0–10% и расстояние больше {THRESHOLD} — "
          "PDQ/vPDQ не считает копию дубликатом.")


if __name__ == "__main__":
    main()
