plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

val fsVersionName = (project.findProperty("fsVersionName") as String?) ?: "1.0.0"
val fsVersionCode = ((project.findProperty("fsVersionCode") as String?) ?: "1").toInt()
// 更新检查接口。默认走 GitHub；本地联调时用 -PfsUpdateApi=http://127.0.0.1:8080/latest 覆盖，
// 生产构建不传这个参数，产出的包与写死的地址完全一致。
val fsUpdateApi = (project.findProperty("fsUpdateApi") as String?)
    ?: "https://api.github.com/repos/VVCY/FollowSound/releases/latest"
// 国内加速前缀（逗号分隔）。前缀 + 上面的接口地址 = 一个可用源，
// 直连永远排在最后兜底。某个反代挂了不用发版：改这里重编即可，也可以随时增删。
val fsUpdateMirrors = (project.findProperty("fsUpdateMirrors") as String?)
    ?: "https://gh-proxy.com/"

android {
    namespace = "app.followsound.android"
    compileSdk = 35

    defaultConfig {
        applicationId = "app.followsound.android"
        minSdk = 26
        targetSdk = 35
        versionCode = fsVersionCode
        versionName = fsVersionName
        buildConfigField("String", "UPDATE_API", "\"$fsUpdateApi\"")
        buildConfigField("String", "UPDATE_MIRRORS", "\"$fsUpdateMirrors\"")
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
