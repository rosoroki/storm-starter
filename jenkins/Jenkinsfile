#!groovy

stage 'Dev'
node {
    checkout scm
    sh "jenkins/build-dev.sh"
}

stage 'QA'
node {
    checkout scm
    sh "jenkins/build-qa.sh"
}
