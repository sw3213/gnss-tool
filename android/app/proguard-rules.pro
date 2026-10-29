# 릴리스 빌드는 R8로 코드를 줄임. MapLibre 네이티브(C++) 엔진은 자바 클래스·메서드를 이름으로
# 찾아 부르는데(JNI), SDK에 들어 있는 keep 규칙은 일부뿐이라 지워지거나 이름이 바뀌면 지도를
# 여는 순간 앱이 죽을 수 있음 -> MapLibre와 플러그인 코드는 통째로 보존
-keep class org.maplibre.** { *; }
-keep interface org.maplibre.** { *; }
-dontwarn org.maplibre.**
