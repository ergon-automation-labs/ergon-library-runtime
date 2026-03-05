// Jenkins Pipeline for bot_army_runtime library
// Downloads pre-built releases from GitHub and deploys to library repository

pipeline {
  agent { label 'built-in' }

  options {
    timeout(time: 30, unit: 'MINUTES')
    timestamps()
  }

  triggers {
    // Poll GitHub every 5 minutes for new commits
    pollSCM('H/5 * * * *')
  }

  environment {
    GITHUB_REPO = "ergon-automation-labs/ergon-runtime"
    LIBRARY_NAME = "bot_army_runtime"
    LIBRARY_DIR = "/opt/ergon/libraries/bot_army_runtime"
  }

  stages {

    stage('Checkout') {
      steps {
        checkout scm
      }
    }

    stage('Download Build Artifact') {
      steps {
        sh '''
          echo "==============================================="
          echo "Downloading pre-built library release from GitHub"
          echo "==============================================="

          # Get the latest published release (not a draft)
          LATEST_RELEASE=$(gh api repos/${GITHUB_REPO}/releases \
            -q '.[] | select(.draft==false) | .tag_name' | head -1)

          if [ -z "$LATEST_RELEASE" ]; then
            echo "ERROR: No published release found on GitHub"
            exit 1
          fi

          echo "Latest release: $LATEST_RELEASE"

          # Download the tarball asset
          echo "Downloading: ${LIBRARY_NAME}-*.tar.gz"
          mkdir -p ./release-artifact

          gh release download $LATEST_RELEASE \
            --repo ${GITHUB_REPO} \
            --pattern "*.tar.gz" \
            -D ./release-artifact

          echo "✓ Release downloaded successfully"

          # Extract tarball
          cd ./release-artifact
          TARBALL=$(ls -1 *.tar.gz | head -1)
          echo "Extracting: $TARBALL"
          tar -xzf "$TARBALL"
          rm "$TARBALL"
          ls -la
          cd ..
        '''
      }
    }

    stage('Deploy Library') {
      steps {
        sh '''
          echo "==============================================="
          echo "Deploying library to artifact repository"
          echo "==============================================="
          echo "Start time: $(date)"

          TIMESTAMP=$(date +%Y%m%d%H%M%S)
          DEST="${LIBRARY_DIR}/releases/${TIMESTAMP}"

          echo "Creating library directory..."
          mkdir -p "${DEST}"

          echo "Copying library artifacts..."
          cp -r ./release-artifact/* "${DEST}/"

          echo "Updating current symlink..."
          ln -sfn "${DEST}" "${LIBRARY_DIR}/current"

          echo "Deploy complete!"
          echo "Completion time: $(date)"
          echo "Library deployed to: ${LIBRARY_DIR}/current"
        '''
      }
    }

  }

  post {
    success {
      sh '''
        echo "✅ Library release deployment successful"
        echo "Library: ${LIBRARY_NAME}"
        echo "Location: ${LIBRARY_DIR}/current"
      '''
    }
    failure {
      sh '''
        echo "❌ Library release deployment failed"
        echo "Check logs above for details"
      '''
    }
    always {
      cleanWs()
    }
  }
}
