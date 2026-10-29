OWNER="jellyfin"
GROUP="nubmen"
MEDIA_PATH="/media"



echo "Fixing ownership for $MEDIA_PATH ..."
sudo chown -R $OWNER:$GROUP "$MEDIA_PATH"

echo "Setting directory permissions (755) ..."
sudo find "$MEDIA_PATH" -type d -exec chmod 775 {} \;

echo "Setting file permissions (664) ..."
sudo find "$MEDIA_PATH" -type f -exec chmod 664 {} \;

echo "Removing execute from .nfo permissions (g-x) ..."
sudo find "$MEDIA_PATH" -type f -name "*\.nfo" -exec chmod g-w {} \;

echo "Done! Permissions fixed for $MEDIA_PATH."
