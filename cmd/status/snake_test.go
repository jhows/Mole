package main

import "testing"

func TestSnakeWrapsAroundWithoutDying(t *testing.T) {
	g := newSnakeGame(10)
	g.food = snakePoint{9, 3}
	for i := 0; i < 25; i++ {
		g.step()
	}
	if g.over {
		t.Fatalf("snake died going straight, body=%v", g.body)
	}
	if len(g.body) != 3 {
		t.Fatalf("body length = %d, want 3", len(g.body))
	}
}

func TestSnakeEatsFoodAndGrows(t *testing.T) {
	g := newSnakeGame(10)
	g.food = snakePoint{4, 1}
	g.step()
	if g.score != 1 || len(g.body) != 4 {
		t.Fatalf("score=%d len=%d, want 1 and 4", g.score, len(g.body))
	}
}

func TestSnakeCannotReverseAndEndsOnSelfHit(t *testing.T) {
	g := newSnakeGame(10)
	g.turn(snakePoint{-1, 0})
	g.step()
	if g.dir != (snakePoint{1, 0}) {
		t.Fatalf("reversed into itself: dir=%v", g.dir)
	}
	g.body = []snakePoint{{3, 1}, {3, 2}, {2, 2}, {2, 1}, {2, 0}}
	g.dir, g.next = snakePoint{0, 1}, snakePoint{-1, 0}
	g.food = snakePoint{9, 3}
	g.step()
	if !g.over {
		t.Fatalf("expected game over after hitting body, head=%v", g.body[0])
	}
}
