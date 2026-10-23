import 'package:flutter_test/flutter_test.dart';
import 'package:giki/srs/srs.dart';

void main() {
  final now = DateTime.utc(2026, 10, 23, 10);

  test('a fresh card is due immediately', () {
    final state = ReviewState.fresh(now);
    expect(state.box, 1);
    expect(state.reps, 0);
    expect(state.dueAt, now);
  });

  test('good promotes one box and schedules that box\'s interval', () {
    final state = schedule(ReviewState.fresh(now), Rating.good, now);
    expect(state.box, 2);
    expect(state.intervalDays, boxIntervalDays[2]);
    expect(state.dueAt, now.add(Duration(days: boxIntervalDays[2])));
    expect(state.reps, 1);
    expect(state.lapses, 0);
  });

  test('easy skips a box', () {
    final state = schedule(ReviewState.fresh(now), Rating.easy, now);
    expect(state.box, 3);
  });

  test('again drops back to box 1 and counts a lapse', () {
    var state = ReviewState.fresh(now);
    for (var i = 0; i < 3; i++) {
      state = schedule(state, Rating.good, now);
    }
    expect(state.box, 4);

    final lapsed = schedule(state, Rating.again, now);
    expect(lapsed.box, 1);
    expect(lapsed.lapses, 1);
    expect(lapsed.intervalDays, 0);
    expect(lapsed.dueAt, now);
  });

  test('hard steps back one box but never below the first', () {
    final state = schedule(ReviewState.fresh(now), Rating.hard, now);
    expect(state.box, 1);
    expect(state.lapses, 0);
  });

  test('the ladder stops at the top box', () {
    var state = ReviewState.fresh(now);
    for (var i = 0; i < 20; i++) {
      state = schedule(state, Rating.easy, now);
    }
    expect(state.box, maxBox);
    expect(state.intervalDays, boxIntervalDays[maxBox]);
  });

  test('ratings round trip through their stored values', () {
    for (final rating in Rating.values) {
      expect(Rating.fromValue(rating.value), rating);
    }
    expect(() => Rating.fromValue(9), throwsArgumentError);
  });
}
