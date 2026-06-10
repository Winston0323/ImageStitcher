allprojects {
    repositories {
        maven { url = uri("https://maven.aliyun.com/repository/google") }
        maven { url = uri("https://maven.aliyun.com/repository/central") }
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}

// 避免 :app 对自己 evaluationDependsOn 造成循环依赖
subprojects {
    if (project.name != "app") {
        project.evaluationDependsOn(":app")
    }
}

// 强制所有插件子项目使用 compileSdk 36（解决 file_picker compileSdk=34 问题）
subprojects {
    if (project.name != "app") {
        afterEvaluate {
            try {
                extensions.configure<com.android.build.api.dsl.LibraryExtension>("android") {
                    compileSdk = 36
                }
            } catch (_: Exception) {
                try {
                    extensions.configure<com.android.build.api.dsl.ApplicationExtension>("android") {
                        compileSdk = 36
                    }
                } catch (_: Exception) { }
            }
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
