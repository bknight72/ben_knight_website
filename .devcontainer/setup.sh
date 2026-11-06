#!/bin/sh
set -eu
# Both analysis contexts must resolve inside this container, never on the host.
flutter config --no-analytics
flutter pub get
(
  cd budgeting
  flutter pub get
)
