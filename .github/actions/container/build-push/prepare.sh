#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf '::error::%s\n' "$1" >&2
  exit 1
}

[[ -d "$CLEARENT_APPLICATION_DIRECTORY" ]] ||
  fail "The application directory does not exist."
[[ "$CLEARENT_CONTAINER_REGISTRY" =~ ^[a-z0-9.-]+(:[0-9]+)?$ ]] ||
  fail "registry must be a canonical lowercase hostname with an optional port."
[[ "$CLEARENT_IMAGE_REPOSITORY" =~ ^[a-z0-9]+([._/-][a-z0-9]+)*$ ]] ||
  fail "image-repository is not a canonical lowercase repository path."
case "$CLEARENT_PUSH_LATEST" in
  [Tt][Rr][Uu][Ee]) push_latest="true" ;;
  [Ff][Aa][Ll][Ss][Ee]) push_latest="false" ;;
  *) fail "push-latest must be true or false." ;;
esac

for relative_path in "$CLEARENT_BUILD_CONTEXT" "${CLEARENT_DOCKERFILE:-Dockerfile}"; do
  if [[ "$relative_path" == /* || "/$relative_path/" == *"/../"* ]]; then
    fail "Docker paths must be relative and must not contain '..' segments."
  fi
done

application_directory="$(cd "$CLEARENT_APPLICATION_DIRECTORY" && pwd -P)"
context_path="$(cd "$application_directory/$CLEARENT_BUILD_CONTEXT" 2>/dev/null && pwd -P)" ||
  fail "The Docker build context does not exist."
[[ "$context_path" == "$application_directory" || "$context_path" == "$application_directory/"* ]] ||
  fail "The Docker build context escapes the application directory."

if [[ -n "$CLEARENT_DOCKERFILE" ]]; then
  dockerfile_path="$application_directory/$CLEARENT_DOCKERFILE"
  [[ -f "$dockerfile_path" ]] || fail "The configured Dockerfile does not exist."
else
  dockerfiles=()
  while IFS= read -r -d '' discovered_dockerfile; do
    dockerfiles[${#dockerfiles[@]}]="$discovered_dockerfile"
  done < <(
    find "$context_path" -type f -name Dockerfile -not -path '*/.git/*' -print0
  )
  [[ "${#dockerfiles[@]}" -eq 1 ]] ||
    fail "Exactly one Dockerfile must be discoverable when dockerfile is omitted."
  dockerfile_path="${dockerfiles[0]}"
fi

image_tag="$CLEARENT_IMAGE_TAG"
if [[ -z "$image_tag" ]]; then
  short_sha="${GITHUB_SHA:-unknown}"
  short_sha="${short_sha:0:4}"
  image_tag="$(date -u +%Y%m%d%H%M%S)$short_sha"
fi
[[ "$image_tag" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] ||
  fail "image-tag is not a valid Docker tag."

image_name="$CLEARENT_CONTAINER_REGISTRY/$CLEARENT_IMAGE_REPOSITORY"
image_reference="$image_name:$image_tag"

{
  printf 'image-tag=%s\n' "$image_tag"
  printf 'image-reference=%s\n' "$image_reference"
  printf 'context=%s\n' "$context_path"
  printf 'dockerfile=%s\n' "$dockerfile_path"
  delimiter="clearent_tags_${RANDOM}_${RANDOM}"
  printf 'tags<<%s\n' "$delimiter"
  printf '%s\n' "$image_reference"
  if [[ "$push_latest" == "true" ]]; then
    printf '%s:latest\n' "$image_name"
  fi
  printf '%s\n' "$delimiter"
} >>"${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"
