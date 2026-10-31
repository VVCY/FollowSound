plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

val fsVersionName = (project.findProperty("fsVersionName") as String?) ?: "1.0.0"
val fsVersionCode = ((project.findProperty("fsVersionCode") as String?) ?: "1").toInt()

android {
    namespace = "app.followsound.android"
    compileSdk = 35

    defaultConfig {
        applicationId = "app.followsound.android"
        minSdk = 26
        targetSdk = 35
        versionCode = fsVersionCode
        versionName = fsVersionName
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            // 无签名密钥时用 debug 签名，保证 CI 能产出可安装的 APK
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    buildFeatures {
        // Updater 里要读 BuildConfig.VERSION_NAME 做版本比较
        buildConfig = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
}

// 视觉核心与 macOS / Windows / 网页是同一份代码，构建前同步进 assets，避免仓库里出现副本
val syncShared = tasks.register<Copy>("syncShared") {
    from(rootProject.file("../shared"))
    into(layout.projectDirectory.dir("src/main/assets"))
}
tasks.named("preBuild") { dependsOn(syncShared) }

dependencies {
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("androidx.appcompat:appcompat:1.7.0")
    implementation("androidx.webkit:webkit:1.11.0")
    implementation("com.google.android.material:material:1.12.0")
}
