package main

import "fmt"

func g() (n int) {
	defer func() { n *= 2 }()
	n = 3
	return n + 1
}

func main() {
	for i := 0; i < 3; i++ {
		defer fmt.Print(i)
	}
	var m map[string]int
	fmt.Println(m["x"], len(m), g())
}
