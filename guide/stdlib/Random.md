# Random

Random numbers, random picks, shuffles, and weighted coin flips.

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

## Random.shuffle(array)

A new array with the elements of `array` in a random order. `array` itself is left unchanged. An empty `array` gives an empty array.

```
let deck = ["ace", "king", "queen", "jack"]
let shuffled = Random.shuffle(deck)   # e.g. ["queen", "ace", "jack", "king"]; deck is unchanged
```

To shuffle an array in place, assign the result back: `deck = Random.shuffle(deck)`. Other references to the old array still see the original order.

## Random.odds(p)

`true` with probability `p`, `false` with probability `1 - p` — `p` is a plain 0.0–1.0 probability, not a weight or a ratio.

```
Random.odds(0.5)    # a fair coin flip
Random.odds(0.75)   # true 75% of the time
Random.odds(0)      # always false
Random.odds(1)      # always true
```
