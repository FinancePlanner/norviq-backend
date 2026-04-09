# CI/CD and Migration Strategy

This document outlines the CI/CD options for the StockPlan project (iOS App, Vapor Backend, Shared Package, and Bruno Collections) and details the strategy, advantages, and disadvantages of migrating from GitHub Actions to GitLab CI/CD.

## CI/CD Provider Alternatives

Since the project consists of a native iOS app (SwiftUI) and a Swift backend (Vapor), the CI/CD provider needs strong support for macOS build environments (for Xcode and the iOS simulator) and Linux/Docker environments (for the backend).

### 1. Xcode Cloud (Apple's Native CI/CD)
* **Best for:** The iOS app (`StockPlanIOSApp`)
* **Pros:** Deeply integrated into Xcode and App Store Connect. Requires almost zero setup compared to YAML scripts. Automatically handles code signing, provisioning profiles, simulator tests, and TestFlight distributions.
* **Cons:** Exclusively for Apple platforms. Cannot build, test, or deploy the Vapor backend.
* **Pricing:** Includes a generous free tier for Apple Developer Program members.

### 2. GitLab CI/CD
* **Best for:** An all-in-one alternative to GitHub
* **Pros:** Built-in CI/CD is mature and cohesive. Uses a `.gitlab-ci.yml` syntax. Offers shared macOS runners and standard Linux runners. Built-in Container Registry.
* **Cons:** Shared macOS runners consume CI/CD minutes quickly.

### 3. Bitrise
* **Best for:** Mobile-first teams who want a visual workflow builder
* **Pros:** Top-tier macOS infrastructure. Drag-and-drop workflow editor makes it easy to set up complex iOS pipelines. Supports Docker/Linux for the Vapor backend.
* **Cons:** Can get expensive as team or build minutes grow.

### 4. CircleCI
* **Best for:** Advanced customization and speed
* **Pros:** Very fast and highly customizable. Excellent macOS compute options and robust Docker support. Strong caching features for Swift Package Manager (SPM).
* **Cons:** Configuration syntax can be complex to master.

### 5. Codemagic
* **Best for:** Mobile-focused alternative to Bitrise
* **Pros:** Fast Apple Silicon (M1/M2) build machines reduce Xcode compile times. Quick to support new Xcode betas.
* **Cons:** Less focused on general backend deployments.

---

## Migrating from GitHub to GitLab

Moving the entire Swift full-stack project (monorepo) from GitHub to GitLab is a solid strategic choice for a highly integrated, single-platform experience.

### Advantages
1. **Superior, Built-in CI/CD (GitLab CI):** Defining pipelines in a single `.gitlab-ci.yml` file with a visual pipeline graph makes troubleshooting multi-stage builds (Shared package -> iOS app -> Docker backend) easier.
2. **Integrated Container Registry:** A robust, built-in Docker Container Registry for every project. Perfect for the Vapor backend (`StockPlanBackend`).
3. **All-in-One Platform:** Provides source control, CI/CD, issue tracking, wikis, and security scanning in one place.
4. **Self-Hosting Option:** Offers a fully featured self-hosted version for absolute control over infrastructure and sensitive user data.

### Disadvantages
1. **Smaller Ecosystem (Marketplace):** Lacks the massive open-source marketplace of GitHub Actions. Niche steps may require custom bash or Docker scripts.
2. **macOS Runner Costs:** Building `StockPlanIOSApp` requires macOS runners, which are heavily "weighted" on GitLab SaaS and consume free CI/CD minutes quickly.
3. **Migration Overhead:** Requires rewriting existing `.github/workflows` into `.gitlab-ci.yml` syntax.

### Migration Steps

#### Phase 1: Git Migration
1. **Create a GitLab Account & Project:** Create a blank project named `StockProject` on gitlab.com. Do not initialize with a README.
2. **Update Local Remote:**
   ```bash
   git remote remove origin
   git remote add origin git@gitlab.com:yourusername/StockProject.git
   ```
3. **Push Code:**
   ```bash
   git push -u origin main
   git push --tags
   ```

#### Phase 2: CI/CD Migration
1. **Delete GitHub Actions:**
   ```bash
   rm -rf .github/workflows
   ```
2. **Create `.gitlab-ci.yml`:** Create a new file named `.gitlab-ci.yml` in the root of the project.
3. **Replicate Pipelines:** Translate workflows. Example Vapor backend test stage:
   ```yaml
   image: swift:5.10

   stages:
     - test
     - build

   test_backend:
     stage: test
     script:
       - cd StockPlanBackend
       - swift test
   ```
   *(Note: For the iOS app, specify a macOS runner using `tags: [saas-macos-medium-m1]`.)*

#### Phase 3: Infrastructure Setup
1. **Configure Variables:** Move secrets to GitLab's **Settings > CI/CD > Variables**.
2. **Update Docker Deployments:** Update backend deployment scripts to pull from the GitLab Container Registry (`registry.gitlab.com`).
3. **(Optional) Register a Local Runner:** Install GitLab Runner on a local Mac to build the iOS app for free without consuming SaaS macOS minutes.
