fun int main() =
    let n = 10 in
    let {a, b} = {replicate(n,0), replicate(n,0)} in
    let a[0] = 1 in
    let b[0] = 2 in
    a[0] + b[0]