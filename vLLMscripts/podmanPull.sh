if podman image exists "$IMAGE"; then
    echo "Success: $IMAGE is available locally."
else
    echo "Warning: $IMAGE is not found locally. It needs to be pulled."
fi
