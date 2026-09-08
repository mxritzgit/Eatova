Map<String, dynamic> trainingDraft() => {
  'schema_version': 1,
  'title': 'Two sessions',
  'description': 'Keep a comfortable pace.',
  'goal': 'Consistency',
  'workouts': [
    {
      'title': 'Session A',
      'description': '',
      'exercises': [
        {
          'name': 'Chair squat',
          'sets': 2,
          'reps': 8,
          'duration_seconds': null,
          'rest_seconds': 30,
          'notes': '',
        },
        {
          'name': 'Easy march',
          'sets': 2,
          'reps': null,
          'duration_seconds': 40,
          'rest_seconds': 15,
          'notes': 'Use a comfortable range.',
        },
      ],
    },
  ],
};

Map<String, dynamic> firstWorkout(Map<String, dynamic> plan) =>
    (plan['workouts'] as List).first as Map<String, dynamic>;

Map<String, dynamic> firstExercise(Map<String, dynamic> plan) =>
    (firstWorkout(plan)['exercises'] as List).first as Map<String, dynamic>;

Map<String, dynamic> trainingMessage({Object? role = 'assistant'}) => {
  'id': 'server-message-1',
  'role': role,
  'content': 'Please review before saving.',
  'created_at': '2026-09-08T12:00:00Z',
  'refusal': false,
  'training_plan': trainingDraft(),
};

Map<String, dynamic> trainingReply() => {
  'reply': 'Please review before saving.',
  'session_id': 'session-A',
  'assistant_message_id': 'server-message-1',
  'training_plan': trainingDraft(),
  'remaining': 4,
  'daily_limit': 5,
};
