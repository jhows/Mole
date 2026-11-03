//go:build !darwin

package main

import (
	"fmt"
	"os"
)

func main() {
	fmt.Fprintln(os.Stderr, "analyze só é suportado no macOS")
	os.Exit(1)
}
