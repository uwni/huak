#let styled(size: none, fill: none, weight: none, body) = {
  if size != none and fill != none and weight != none {
    text(size: size, fill: fill, weight: weight, body)
  } else if size != none and fill != none {
    text(size: size, fill: fill, body)
  } else if fill != none {
    text(fill: fill, body)
  } else {
    body
  }
}
#let header(size, fill, body) = text(size: size, fill: fill, body)
#let plot-title(size, weight, body) = text(size: size, weight: weight, body)
