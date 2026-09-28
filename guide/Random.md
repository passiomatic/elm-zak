# Random

Random numbers, random picks, and weighted coin flips.

## Random.number(start, end)

A random number in `[start, end]`, inclusive.

```
Random.number(1, 10)      # a number between 1 and 10
Random.number(0.0, 1.0)   # a number between 0 and 1
```

## Random.pick(array)

A random element of `array`, picked with equal probability. Errors if `array` is empty.

```
Random.pick(["a", "b", "c"])   # "a", "b", or "c", each equally likely
```

## Random.odds(p)

`true` with probability `p`, `false` with probability `1 - p` — `p` is a plain 0.0–1.0 probability, not a weight or a ratio.

```
Random.odds(0.5)    # a fair coin flip
Random.odds(0.75)   # true 75% of the time
Random.odds(0)      # always false
Random.odds(1)      # always true
```
