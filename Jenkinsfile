pipeline {
  agent { label 'built-in' }

  options {
    timeout(time: 30, unit: 'MINUTES')
    timestamps()
  }

  environment {
    MIX_ENV = 'test'
    LIB_NAME = 'bot_army_runtime'
  }

  stages {

    stage('Checkout') {
      steps {
        checkout scm
      }
    }

    stage('Lint') {
      steps {
        sh '''
          echo "Running linting..."
          mix credo --strict
        '''
      }
    }

    stage('Test') {
      steps {
        sh '''
          echo "Installing dependencies..."
          mix deps.get
          echo "Running tests..."
          mix test
        '''
      }
    }

    stage('Dialyzer') {
      steps {
        sh '''
          echo "Running static type analysis..."
          mix dialyzer
        '''
      }
    }

    stage('Docs') {
      steps {
        sh '''
          echo "Generating documentation..."
          mix docs
        '''
      }
    }

  }

  post {
    success {
      sh '''
        VERSION=$(grep "version:" mix.exs | head -1 | grep -oE '"[^"]+"' | tr -d '"')
        /opt/bot_army/scripts/nats_publish.sh ops.library.build.success \
          "{\"library\":\"${LIB_NAME}\",\"version\":\"${VERSION}\",\"node\":\"air\",\"triggered_by\":\"jenkins\",\"status\":\"success\"}"
      '''
    }
    failure {
      sh '''
        /opt/bot_army/scripts/nats_publish.sh ops.library.build.failed \
          "{\"library\":\"${LIB_NAME}\",\"node\":\"air\",\"triggered_by\":\"jenkins\",\"status\":\"failed\"}"
      '''
    }
  }
}
