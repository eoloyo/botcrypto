plugins {
    `java-library`
}

java {
    toolchain { languageVersion = JavaLanguageVersion.of(21) }
}

repositories {
    maven { url = uri("https://repo1.maven.org/maven2/") }
    mavenCentral()
}

val jenaVersion: String by project
val junitVersion: String by project

dependencies {
    // SPARQL parsing/algebra + remote SPARQL client (talks to a Fuseki HTTP endpoint)
    api("org.apache.jena:jena-arq:$jenaVersion")

    // Tests boot a REAL Fuseki server in-process (jena-fuseki-main)
    testImplementation("org.apache.jena:jena-fuseki-main:$jenaVersion")
    testImplementation(platform("org.junit:junit-bom:$junitVersion"))
    testImplementation("org.junit.jupiter:junit-jupiter")
    testRuntimeOnly("org.junit.platform:junit-platform-launcher")
    testRuntimeOnly("org.slf4j:slf4j-simple:2.0.13")
}

tasks.test {
    useJUnitPlatform()
    testLogging { events("passed", "failed", "skipped") }
}
