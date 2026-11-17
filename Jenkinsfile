pipeline {
  agent any
  options {
    skipDefaultCheckout(true)
    disableConcurrentBuilds()
    buildDiscarder(logRotator(numToKeepStr: '20'))
    timestamps()
    timeout(time: 30, unit: 'MINUTES')
  }

  environment {
    HARBOR_REGISTRY = "registry.farmstomarket.co"
    HARBOR_PROJECT  = "farmstomarket"
    IMAGE_NAME      = "agri-harvest-cameroon"
  }

  triggers {
    githubPush()
  }

  stages {
    stage('Checkout') {
      steps {
        checkout scm
        script {
          env.SHORT_SHA = sh(script: "git rev-parse --short HEAD", returnStdout: true).trim()
          echo "Building ${IMAGE_NAME} | branch ${env.BRANCH_NAME} | commit ${env.SHORT_SHA}"
        }
      }
    }

    stage('Syntax Check') {
      steps {
        script {
          docker.image('python:3.12-slim').inside('-e HOME=/tmp -e PYTHONDONTWRITEBYTECODE=1') {
            sh 'python -m compileall -q . || { echo "Syntax errors found"; exit 1; }'
          }
        }
      }
    }

    stage('Docker Build (Local)') {
      when { anyOf { branch 'develop'; branch 'main' } }
      steps {
        script {
          env.IMAGE_TAG = "${HARBOR_REGISTRY}/${HARBOR_PROJECT}/${IMAGE_NAME}:${env.BRANCH_NAME}-${env.SHORT_SHA}"
          echo "Target image: ${env.IMAGE_TAG}"
          sh '''
            docker buildx create --use --name f2mbuilder 2>/dev/null || docker buildx use f2mbuilder
            docker buildx inspect --bootstrap >/dev/null
            docker buildx build --load \
              --label "org.opencontainers.image.revision=${SHORT_SHA}" \
              -t "${IMAGE_TAG}" \
              -t "${HARBOR_REGISTRY}/${HARBOR_PROJECT}/${IMAGE_NAME}:latest" \
              .
          '''
        }
      }
    }

    stage('Security Scan (Trivy)') {
      when { anyOf { branch 'develop'; branch 'main' } }
      steps {
        sh '''
          if ! command -v trivy >/dev/null 2>&1; then
            echo "Trivy not found - bootstrapping to workspace..."
            curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sh -s -- -b "$WORKSPACE/.trivybin" || true
            export PATH="$WORKSPACE/.trivybin:$PATH"
          fi
          if command -v trivy >/dev/null 2>&1 || [ -x "$WORKSPACE/.trivybin/trivy" ]; then
            TRIVY="$(command -v trivy || echo "$WORKSPACE/.trivybin/trivy")"
            "$TRIVY" image --scanners vuln --severity CRITICAL,HIGH --ignore-unfixed --no-progress --exit-code 0 "${IMAGE_TAG}" || echo "Trivy reported issues - continuing"
          else
            echo "Trivy unavailable - skipping scan"
          fi
        '''
      }
    }

    stage('Push Image') {
      when { anyOf { branch 'develop'; branch 'main' } }
      steps {
        withCredentials([usernamePassword(credentialsId: 'harbor-creds', usernameVariable: 'HARBOR_USERNAME', passwordVariable: 'HARBOR_PASSWORD')]) {
          sh '''
            echo "$HARBOR_PASSWORD" | docker login ${HARBOR_REGISTRY} -u "$HARBOR_USERNAME" --password-stdin
            docker push "${IMAGE_TAG}"
            docker push "${HARBOR_REGISTRY}/${HARBOR_PROJECT}/${IMAGE_NAME}:latest"
          '''
        }
      }
    }

    stage('Sign Image') {
      when { anyOf { branch 'develop'; branch 'main' } }
      steps {
        script {
          try {
            withCredentials([
              file(credentialsId: 'cosign-key', variable: 'COSIGN_KEY'),
              string(credentialsId: 'cosign-password', variable: 'COSIGN_PASSWORD'),
              usernamePassword(credentialsId: 'harbor-creds', usernameVariable: 'HARBOR_USERNAME', passwordVariable: 'HARBOR_PASSWORD')
            ]) {
              sh '''
                echo "$HARBOR_PASSWORD" | cosign login ${HARBOR_REGISTRY} -u "$HARBOR_USERNAME" --password-stdin
                cosign sign --yes --key "$COSIGN_KEY" "${IMAGE_TAG}"
              '''
            }
          } catch (err) {
            echo "Image signing skipped: ${err.message}"
          }
        }
      }
    }

    stage('GitOps Deploy') {
      when { anyOf { branch 'develop'; branch 'main' } }
      steps {
        withCredentials([string(credentialsId: 'gitops-token', variable: 'GITOPS_TOKEN')]) {
          script {
            def overlay = env.BRANCH_NAME == 'main' ? "production" : "staging"
            sh """
              rm -rf gitops-config || true
              git clone --depth 1 https://oauth2:\${GITOPS_TOKEN}@github.com/farmstomarket/gitops-config.git gitops-config || { echo 'gitops clone failed - skipping deploy'; exit 0; }
              cd gitops-config
              OVERLAY_PATH=\$(find apps -type d -path "*/${IMAGE_NAME}/overlays/${overlay}" | head -1)
              if [ -z "\$OVERLAY_PATH" ]; then
                echo "No gitops overlay for ${IMAGE_NAME}/${overlay} - skipping deploy"
                exit 0
              fi
              echo "Updating \$OVERLAY_PATH"
              ( cd "\$OVERLAY_PATH" && kustomize edit set image ${IMAGE_NAME}=${IMAGE_TAG} )
              git config user.name "Jenkins CI"
              git config user.email "jenkins@farmstomarket.co"
              git add .
              git commit -m "Deploy ${IMAGE_NAME} ${IMAGE_TAG} [ci skip]" || echo "No changes to commit"
              git push origin HEAD || echo 'Push failed - check token/permissions'
            """
          }
        }
      }
    }
  }

  post {
    success {
      script {
        try {
          slackSend(channel: '#ci-cd', color: 'good', message: "SUCCESS: ${env.JOB_NAME} #${env.BUILD_NUMBER} (${env.BRANCH_NAME}) - Image: ${env.IMAGE_TAG ?: 'build only'}")
        } catch (err) { echo "Slack notification skipped: ${err.message}" }
        try {
          emailext(subject: "SUCCESS: ${env.JOB_NAME} #${env.BUILD_NUMBER} (${env.BRANCH_NAME})",
            body: "Build succeeded.\nImage: ${env.IMAGE_TAG ?: 'N/A'}\nDetails: ${env.BUILD_URL}",
            recipientProviders: [culprits(), requestor()])
        } catch (err) { echo "Email notification skipped: ${err.message}" }
      }
    }
    failure {
      script {
        try {
          slackSend(channel: '#ci-cd', color: 'danger', message: "FAILED: ${env.JOB_NAME} #${env.BUILD_NUMBER} (${env.BRANCH_NAME}) - Check console")
        } catch (err) { echo "Slack notification skipped: ${err.message}" }
        try {
          emailext(subject: "FAILED: ${env.JOB_NAME} #${env.BUILD_NUMBER} (${env.BRANCH_NAME})",
            body: "Build failed. Console: ${env.BUILD_URL}",
            recipientProviders: [culprits(), requestor(), brokenBuildSuspects()])
        } catch (err) { echo "Email notification skipped: ${err.message}" }
      }
    }
    always {
      cleanWs(deleteDirs: true, disableDeferredWipeout: true)
    }
  }
}
