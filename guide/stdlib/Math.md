# Math

Trigonometry, rounding, and the constant `pi`.

## Basics

### Math.min(a, b)

The smaller of `a` and `b`.
```
Math.min(3, 7)   # 3
```

### Math.max(a, b)

The larger of `a` and `b`.
```
Math.max(3, 7)   # 7
```

### Math.sqrt(x)

Square root of `x`. Negative `x` is an error.

```
Math.sqrt(16)   # 4
```

### Math.abs(x)

Absolute value of `x`.

```
Math.abs(-4)   # 4
```

### Math.round(x)

Rounds `x` to the nearest whole number. Ties round up, toward positive infinity.

```
Math.round(1.5)    # 2
Math.round(-1.5)   # -1
```

## Trigonometry

### Math.pi

Pi, as a `Number`.

```
Math.pi   # 3.14159265358979
```

### Math.cos(x)

Cosine of angle `x`, in radians.

```
Math.cos(Math.pi / 3)   # 0.5
```

### Math.sin(x)

Sine of angle `x`, in radians.

```
Math.sin(0)   # 0
```

### Math.tan(x)

Tangent of angle `x`, in radians.

```
Math.tan(0)   # 0
```

### Math.acos(x)

Inverse cosine of `x`, in radians. `x` outside `[-1, 1]` is an error, not a `NaN` value.

```
Math.acos(1)   # 0
```

### Math.asin(x)

Inverse sine of `x`, in radians. `x` outside `[-1, 1]` is an error, not a `NaN` value.

```
Math.asin(0)   # 0
```

### Math.atan(x)

Inverse tangent of the ratio `x`, in radians. Only returns angles in a half-circle range — use `Math.atan2` for the angle to a point in the full circle.

```
Math.atan(1)   # 0.785... (45 degrees)
```

### Math.atan2(y, x)

Angle, in radians, to the point `(x, y)` — full-circle range. Note the argument order: `y` comes first.

```
Math.atan2(1, 1)   # 0.785... (45 degrees)
```
