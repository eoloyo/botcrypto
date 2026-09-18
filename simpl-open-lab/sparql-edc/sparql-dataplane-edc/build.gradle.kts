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

val edcVersion: String by project

dependencies {
    // The tested core (guard + Fuseki/SPARQL client) is bundled into the extension.
    implementation(project(":sparql-core"))

    // Eclipse EDC data-plane SPI — provided by the connector runtime at deployment time.
    compileOnly("org.eclipse.edc:data-plane-spi:$edcVersion")
    compileOnly("org.eclipse.edc:core-spi:$edcVersion")
    compileOnly("org.eclipse.edc:boot-spi:$edcVersion")
    compileOnly("org.eclipse.edc:runtime-metamodel:$edcVersion")
}
