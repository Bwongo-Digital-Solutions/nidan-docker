# syntax=docker/dockerfile:1.3
#--------------------------------------------
# Dev Stage - Nidan Uganda configuration uses the Gregorian calendar
# Date display locale is configured in config-core_demo.json and the SPA build config.
#--------------------------------------------
FROM --platform=$BUILDPLATFORM node:22-alpine as dev

ARG APP_SHELL_VERSION=10.0.0

RUN mkdir -p /app
WORKDIR /app

# Configure both Yarn and npm fetch settings. The OpenMRS assembler resolves
# frontend modules independently of the preceding yarn add commands.
ENV npm_config_registry=https://registry.npmjs.org \
    npm_config_fetch_retries=5 \
    npm_config_fetch_retry_mintimeout=20000 \
    npm_config_fetch_retry_maxtimeout=120000 \
    npm_config_fetch_timeout=600000

RUN yarn config set registry https://registry.npmjs.org \
    && yarn config set network-timeout 600000

COPY spa-assemble-config.json spa-build-config.json .

RUN yarn global add husky

# Third-party / fork tarballs (paths must match spa-assemble-config.json)
COPY packages/trigonal-esm-patient-report-app-1.0.0.tgz .
COPY packages/trigonal-esm-ipd-app-1.0.0.tgz .
COPY packages/trigonal-esm-patient-tests-app-1.0.0.tgz .
COPY packages/trigonal-esm-ward-app-1.0.0.tgz .
COPY packages/kenyaemr-esm-imaging-orders-app-4.0.5.tgz .
COPY packages/kenyaemr-esm-procedure-orders-app-4.0.5.tgz .
COPY packages/kenyaemr-esm-medical-supply-orders-app-4.0.5.tgz .
COPY packages/kenyaemr-esm-bed-orders-app-4.0.5.tgz .
COPY packages/openmrs-esm-nidan-core-app-1.0.0.tgz .
COPY packages/openmrs-esm-form-builder-app-3.4.1-trigonal.tgz .
COPY packages/openmrs-esm-form-engine-app-12.1.0-trigonal.tgz .
COPY packages/openmrs-esm-service-queues-app-10.0.2.tgz .
COPY packages/openmrs-esm-paywall-app-1.0.0.tgz .
COPY packages/openmrs-esm-login-app-10.0.0-nidan.tgz .

# Nidan patient-chart fork (@openmrs/esm-patient-chart 12.1.0 + extensions)
COPY packages/openmrs-esm-patient-chart-app-12.1.0.tgz .
COPY packages/openmrs-esm-patient-forms-app-12.1.0.tgz .
COPY packages/openmrs-esm-patient-orders-app-12.1.0.tgz .
COPY packages/openmrs-esm-orderset-app-12.0.1.tgz .
COPY packages/openmrs-esm-patient-orders-fast-app-12.0.1.tgz .
COPY packages/openmrs-esm-patient-medications-app-12.1.0-trigonal.tgz .
COPY packages/openmrs-esm-patient-notes-app-12.1.0.tgz .
COPY packages/openmrs-esm-appointments-app-10.0.2.tgz .
COPY packages/openmrs-esm-odontogram-app-1.0.0.tgz .
COPY packages/openmrs-esm-primary-navigation-app-10.0.0.tgz .

RUN yarn add ./trigonal-esm-patient-report-app-1.0.0.tgz
RUN yarn add ./trigonal-esm-ipd-app-1.0.0.tgz
RUN yarn add ./trigonal-esm-patient-tests-app-1.0.0.tgz
RUN yarn add ./trigonal-esm-ward-app-1.0.0.tgz
RUN yarn add ./kenyaemr-esm-imaging-orders-app-4.0.5.tgz
RUN yarn add ./kenyaemr-esm-procedure-orders-app-4.0.5.tgz
RUN yarn add ./kenyaemr-esm-medical-supply-orders-app-4.0.5.tgz
RUN yarn add ./kenyaemr-esm-bed-orders-app-4.0.5.tgz
RUN yarn add ./openmrs-esm-nidan-core-app-1.0.0.tgz
RUN yarn add ./openmrs-esm-paywall-app-1.0.0.tgz
RUN yarn add ./openmrs-esm-patient-notes-app-12.1.0.tgz
RUN yarn add ./openmrs-esm-login-app-10.0.0-nidan.tgz
RUN yarn add ./openmrs-esm-odontogram-app-1.0.0.tgz
RUN yarn add ./openmrs-esm-primary-navigation-app-10.0.0.tgz


# openmrs CLI must live in /app/node_modules (not npx cache) so patches apply to the same tree `openmrs build` uses.
RUN yarn add openmrs@${APP_SHELL_VERSION:-10.0.0} --legacy-peer-deps
RUN yarn add ./openmrs-esm-form-builder-app-3.4.1-trigonal.tgz
RUN yarn add ./openmrs-esm-form-engine-app-12.1.0-trigonal.tgz
RUN yarn add ./openmrs-esm-service-queues-app-10.0.2.tgz
RUN yarn add ./openmrs-esm-patient-chart-app-12.1.0.tgz
RUN yarn add ./openmrs-esm-patient-forms-app-12.1.0.tgz
RUN yarn add ./openmrs-esm-patient-orders-app-12.1.0.tgz
RUN yarn add ./openmrs-esm-orderset-app-12.0.1.tgz
RUN yarn add ./openmrs-esm-patient-orders-fast-app-12.0.1.tgz
RUN yarn add ./openmrs-esm-patient-medications-app-12.1.0-trigonal.tgz
RUN yarn add ./openmrs-esm-appointments-app-10.0.2.tgz

# Retry transient registry/network failures during SPA dependency resolution.
RUN set -eu; \
    attempt=1; \
    until yarn openmrs assemble --manifest --mode config --config spa-assemble-config.json --target ./spa; do \
      if [ "$attempt" -ge 4 ]; then \
        echo "OpenMRS SPA assembly failed after $attempt attempts"; \
        exit 1; \
      fi; \
      delay=$((attempt * 20)); \
      echo "SPA assembly failed; retrying in ${delay}s (attempt $((attempt + 1))/4)..."; \
      sleep "$delay"; \
      attempt=$((attempt + 1)); \
    done

RUN yarn openmrs build --build-config spa-build-config.json --target ./spa

RUN if [ ! -f ./spa/index.html ]; then echo 'Build failed. Please check the logs above for details. This may have happened because of an update to a library that OpenMRS depends on.'; exit 1; fi

#--------------------------------------------
# Runtime Stage - Published Image
#--------------------------------------------
FROM nginx:1.25-alpine

RUN apk update && \
    apk upgrade && \
    # add more utils for sponge and envsubst
    apk add --no-cache moreutils

# clear any default files installed by nginx
RUN rm -rf /usr/share/nginx/html/*

COPY startup.sh /usr/local/bin/startup.sh
RUN chmod +x /usr/local/bin/startup.sh

# Copy nginx config for SPA routing
COPY nginx.conf /etc/nginx/nginx.conf

COPY --from=dev /app/spa /usr/share/nginx/html
COPY config-core_demo.json /usr/share/nginx/html

COPY /resources/clinicemr-logo.svg /usr/share/nginx/html
COPY /resources/clinicemr-logo-white.svg /usr/share/nginx/html
COPY /resources/billing-logo.jpg /usr/share/nginx/html/billing-logo.jpg

# The repository's legacy favicon.ico contains SVG text, not an ICO binary.
# Keep the actual SVG asset and point the generated SPA document at it.
RUN if [ -f /usr/share/nginx/html/index.html ]; then \
      sed -i 's|/openmrs/favicon.ico|/openmrs/spa/clinicemr-logo.svg|g; s|/favicon.ico|/clinicemr-logo.svg|g' /usr/share/nginx/html/index.html; \
    fi

CMD ["/usr/local/bin/startup.sh"]
