package main

import "fmt"

func main() {
	a := []int{1, 2, 3, 4}
	b := a[:2]
	b = append(b, 9)
	c := append(a, 5)
	c[0] = 7
	fmt.Println(a, len(b), cap(b), c[0], len(c))
}
