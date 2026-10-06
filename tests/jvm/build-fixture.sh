#!/bin/sh
# Build the C06 JVM fixtures with locally installed tools only (no downloads).
# Usage: build-fixture.sh OUTDIR [KOTLIN_LIB_DIR]
# KOTLIN_LIB_DIR must hold kotlin-compiler-embeddable, kotlin-stdlib,
# kotlin-script-runtime, kotlin-reflect, kotlin-daemon-embeddable, annotations and
# kotlinx-coroutines-core-jvm jars (default: Gradle's bundled copies).
set -eu
umask 022
here=$(cd "$(dirname "$0")" && pwd)
out=${1:?usage: build-fixture.sh OUTDIR [KOTLIN_LIB_DIR]}
lib=${2:-/usr/share/java/gradle/lib}
mkdir -p "$out"
out=$(cd "$out" && pwd)
rm -rf "$out/java-classes" "$out/helper-classes" "$out/kotlin-classes"
mkdir -p "$out/java-classes" "$out/helper-classes" "$out/kotlin-classes"
jar1() { ls "$lib"/"$1"-[0-9]*.jar 2>/dev/null | head -n 1; }
manifest="$out/build-manifest.json"

timeout 120 javac -g -d "$out/java-classes" "$here/fixture/C06JavaFixture.java"
(cd "$out/java-classes" && jar --create --file "$out/c06-java-fixture.jar" \
    --main-class xodb.c06j.C06JavaFixture --date 2026-01-01T00:00:00Z .)

compiler=$(jar1 kotlin-compiler-embeddable); stdlib=$(jar1 kotlin-stdlib)
coroutines=$(jar1 kotlinx-coroutines-core-jvm)
kotlin=unavailable
if [ -n "$compiler" ] && [ -n "$stdlib" ] && [ -n "$coroutines" ]; then
    kcp=$compiler:$stdlib:$coroutines
    for name in kotlin-script-runtime kotlin-reflect kotlin-daemon-embeddable annotations; do
        j=$(jar1 "$name"); [ -n "$j" ] && kcp=$kcp:$j
    done
    timeout 120 javac -g -cp "$coroutines:$stdlib" -d "$out/helper-classes" "$here/fixture/ProbeDump.java"
    timeout 300 java -Xmx512m -Djava.awt.headless=true -cp "$kcp" \
        org.jetbrains.kotlin.cli.jvm.K2JVMCompiler -no-stdlib -no-reflect -jvm-target 21 \
        -cp "$stdlib:$coroutines:$out/helper-classes" -d "$out/kotlin-classes" \
        "$here/fixture/C06Fixture.kt"
    cp -r "$out/helper-classes/." "$out/kotlin-classes/"
    (cd "$out/kotlin-classes" && jar --create --file "$out/c06-kotlin-fixture.jar" \
        --main-class xodb.c06.C06Fixture --date 2026-01-01T00:00:00Z .)
    printf '%s\n%s\n' "$stdlib" "$coroutines" > "$out/kotlin-runtime-classpath.txt"
    kotlin=built
fi

sha() { sha256sum "$1" | cut -d' ' -f1; }
{
    printf '{"format":"xodb-c06-build","version":1,\n'
    printf ' "java_version":"%s",\n' "$(java -XshowSettings:properties -version 2>&1 | sed -n 's/^ *java.runtime.version = //p')"
    printf ' "java_vm_version":"%s",\n' "$(java -XshowSettings:properties -version 2>&1 | sed -n 's/^ *java.vm.version = //p')"
    printf ' "javac":"%s",\n' "$(javac -version 2>&1)"
    printf ' "kotlin":"%s",\n' "$kotlin"
    printf ' "artifacts":{\n'
    printf '  "c06-java-fixture.jar":"%s"' "$(sha "$out/c06-java-fixture.jar")"
    if [ "$kotlin" = built ]; then
        printf ',\n  "c06-kotlin-fixture.jar":"%s"' "$(sha "$out/c06-kotlin-fixture.jar")"
        printf ',\n  "%s":"%s"' "$(basename "$compiler")" "$(sha "$compiler")"
        printf ',\n  "%s":"%s"' "$(basename "$stdlib")" "$(sha "$stdlib")"
        printf ',\n  "%s":"%s"' "$(basename "$coroutines")" "$(sha "$coroutines")"
    fi
    printf '\n },\n "sources":{\n'
    printf '  "C06Fixture.kt":"%s",\n' "$(sha "$here/fixture/C06Fixture.kt")"
    printf '  "ProbeDump.java":"%s",\n' "$(sha "$here/fixture/ProbeDump.java")"
    printf '  "C06JavaFixture.java":"%s"\n }}\n' "$(sha "$here/fixture/C06JavaFixture.java")"
} > "$manifest"
echo "kotlin=$kotlin manifest=$manifest"
