plugins {
    kotlin("jvm") version "2.1.10"
    kotlin("plugin.serialization") version "2.1.10"
    id("io.ktor.plugin") version "3.1.1"
    application
}

group = "com.httparena"
version = "1.0.0"

application {
    mainClass.set("com.httparena.ApplicationKt")
}

repositories {
    mavenCentral()
}

dependencies {
    implementation("io.ktor:ktor-server-core:3.1.1")
    implementation("io.ktor:ktor-server-netty:3.1.1")
    implementation("io.ktor:ktor-server-compression:3.1.1")
    implementation("io.ktor:ktor-server-default-headers:3.1.1")
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.7.3")
    implementation("org.xerial:sqlite-jdbc:3.47.2.0")
    implementation("ch.qos.logback:logback-classic:1.5.15")
}

ktor {
    fatJar {
        archiveFileName.set("ktor-httparena.jar")
    }
}

kotlin {
    jvmToolchain(21)
}
