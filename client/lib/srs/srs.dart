/// Spaced repetition scheduling.
///
/// A Leitner box ladder, deliberately: it is a handful of integers that any
/// user can predict, it survives being edited on two devices at once (the
/// state is one small row per card and user), and it needs no floating point
/// to agree across platforms. SM-2 style easiness factors can be layered on
/// later -- the srs_state table already carries the columns.
library;

/// How well a card was recalled.
enum Rating {
  /// Forgotten: back to box 1.
  again(0),

  /// Recalled with effort.
  hard(1),

  /// Recalled.
  good(2),

  /// Instant.
  easy(3);

  const Rating(this.value);

  /// The value stored in review_log.rating.
  final int value;

  /// Rebuilds a Rating from a stored value.
  static Rating fromValue(int value) =>
      Rating.values.firstWhere((r) => r.value == value,
          orElse: () => throw ArgumentError('unknown rating $value'));
}

/// The interval, in days, of each Leitner box, indexed by box number.
///
/// Index 0 is a placeholder: boxes are numbered from 1, so that the box number
/// stored in srs_state.box reads the way a user would say it. Box 1 is 0 days
/// -- a card you just failed comes back in the same session, not tomorrow.
const List<int> boxIntervalDays = [0, 0, 1, 3, 7, 16, 35];

/// The highest box; a card here is considered learned.
int get maxBox => boxIntervalDays.length - 1;

/// The scheduling state of one card for one user.
class ReviewState {
  const ReviewState({
    required this.box,
    required this.intervalDays,
    required this.reps,
    required this.lapses,
    required this.dueAt,
  });

  /// A card that has never been reviewed: due immediately.
  factory ReviewState.fresh(DateTime now) => ReviewState(
        box: 1,
        intervalDays: 0,
        reps: 0,
        lapses: 0,
        dueAt: now.toUtc(),
      );

  final int box;
  final int intervalDays;
  final int reps;
  final int lapses;
  final DateTime dueAt;
}

/// Applies [rating] to [state] and returns the next state.
///
/// Pure function on purpose: scheduling is the part of a learning app users
/// complain about, so it must be testable without a database, a clock or a UI.
ReviewState schedule(ReviewState state, Rating rating, DateTime now) {
  final int nextBox;
  switch (rating) {
    case Rating.again:
      nextBox = 1;
    case Rating.hard:
      nextBox = state.box > 1 ? state.box - 1 : 1;
    case Rating.good:
      nextBox = state.box < maxBox ? state.box + 1 : maxBox;
    case Rating.easy:
      nextBox = state.box + 2 <= maxBox ? state.box + 2 : maxBox;
  }
  final interval = boxIntervalDays[nextBox];
  return ReviewState(
    box: nextBox,
    intervalDays: interval,
    reps: state.reps + 1,
    lapses: rating == Rating.again ? state.lapses + 1 : state.lapses,
    dueAt: now.toUtc().add(Duration(days: interval)),
  );
}
