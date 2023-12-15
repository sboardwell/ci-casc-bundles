def casctoolImage="ghcr.io/kyounger/casc-plugin-dependency-calculation:v4.1.2"

def cascPodYaml="""\
    apiVersion: v1
    kind: Pod
    spec:
      securityContext:
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
      containers:
      - image: $casctoolImage
        name: casctool
        command:
        - sleep
        args:
        - infinity
    """.stripIndent()

def cascAndCiPodYaml="""\
    apiVersion: v1
    kind: Pod
    spec:
      securityContext:
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
      containers:
      - image: $casctoolImage
        name: casctool
        command:
        - sleep
        args:
        - infinity
      - image: cloudbees/cloudbees-core-mm:CI_VERSION
        name: test-controller
        command:
        - sleep
        args:
        - infinity
        resources:
          requests:
            cpu: 1.5
            memory: 4Gi
      - image: alpine/k8s:1.26.11
        name: k8s
        command:
        - sleep
        args:
        - infinity
    """.stripIndent()

pipeline {
    agent none
    environment {
        BRANCH_PREFIX = 'v*'
    }
    options {
      skipStagesAfterUnstable()
      skipDefaultCheckout()
      disableConcurrentBuilds()
    }
    stages {
        stage('Preflight') {
            agent {
                kubernetes {
                    yaml cascPodYaml
                }
            }
            steps {
                checkout scm
                container('casctool') {
                    sh 'cascgen createTestResources' // test resources allows us to determine CI_VERSION from the available validation bundles
                    sh 'DEBUG=1 cascgen pre-commit' // runs casc-generate and fails if there are any differences detected
                    echo "Preflight checks were successful. No unexpected changes when generating the bundles."
                    script {
                      env.CI_VERSION = readFile('test-resources/.ci-versions').trim()
                    }
                }
            }
        }
        stage('Main') {
            agent {
                kubernetes {
                    yaml "${cascAndCiPodYaml.replace('CI_VERSION', env.CI_VERSION)}"
                }
            }
            environment {
                CASC_VALIDATION_LICENSE_KEY = credentials('casc-validation-key')
                CASC_VALIDATION_LICENSE_CERT = credentials('casc-validation-cert')
            }
            stages {
                stage('Test Generation') {
                    steps {
                        checkout scm
                        container('casctool') {
                            sh 'cascgen createTestResources' // test resources allows us to determine CI_VERSION from the available validation bundles
                        }
                    }
                }
                stage('Test Changed Only') {
                    when {
                        changeRequest target: env.BRANCH_PREFIX, comparator: 'GLOB'
                    }
                    steps {
                        container('test-controller') {
                            sh './test-utils.sh getChangedSources' // test resources allows us to determine CI_VERSION from the available validation bundles
                            sh './test-utils.sh runValidationsChangedOnly'
                        }
                    }
                }
                stage('Test All Validations') {
                    when {
                        branch pattern: env.BRANCH_PREFIX, comparator: 'GLOB' // only ask the question on release branches
                    }
                    steps {
                        container('test-controller') {
                            sh './test-utils.sh runValidations'
                        }
                    }
                }
                stage('Summary Report') {
                    steps {
                        catchError(buildResult: 'UNSTABLE', message: 'Problems found with the bundles', stageResult: 'UNSTABLE') {
                            container('casctool') {
                                sh './test-utils.sh getTestResultReport'
                            }
                        }
                        script {
                            currentBuild.description = readFile('test-resources/test-summary.txt')
                        }
                    }
                }
                stage('Deploy') {
                    options {
                        timeout(time:30, unit:'MINUTES')
                    }
                    when {
                        branch pattern: env.BRANCH_PREFIX, comparator: 'GLOB' // only ask the question on release branches
                        beforeInput true
                    }
                    // input {
                    //     message "Should we apply the bundles?"
                    //     ok "Go for it, me 'ol mucker!"
                    //     submitter "admin"
                    //     parameters {
                    //         booleanParam(name: 'DELETE_UNKNOWN_BUNDLES', defaultValue: true, description: 'Removes any bundles which are no longer in the list for this release.')
                    //     }
                    // }
                    steps {
                        container('k8s') {
                            sh  'echo NAMESPACE=cloudbees-core ./test-utils.sh applyBundleConfigMaps'
                        }
                    }
                }
            }
        }
    }
}