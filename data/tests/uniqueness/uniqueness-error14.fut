-- This program tests whether the compiler catches some of the more
-- nasty side cases of aliasing in loops.
-- ==
-- error:

fun int main() =
  let arr = copy(iota(10)) in
  let barr = copy(iota(10)) in
  loop (arr) = for i < 10 do
                 let arr[i] = 0 in -- Consume arr and its aliases...
                 barr -- Because of this, arr should be aliased to barr.
  in barr[0] -- Error, barr has been consumed!
