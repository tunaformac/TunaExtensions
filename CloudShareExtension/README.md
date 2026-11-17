# Cloud Share Extension

Upload files and images from Tuna to your own Amazon S3 (or S3-compatible) storage and get a
public link on the clipboard, much like Dropshare.

## Setup

Open Tuna Settings → Extensions → Cloud Share and choose **Add Destination**:

| Field | Notes |
| --- | --- |
| Endpoint | Leave empty for AWS (`https://s3.<region>.amazonaws.com`). Set it for S3-compatible services. |
| Secret Access Key | Stored in your Mac Keychain. |
| Access Key ID, Region, Bucket | Required. |
| Path Prefix | Optional folder, e.g. `uploads/%year%/%month%`. |
| Public URL | Optional base for links, e.g. `https://files.example.com`. Defaults to the S3 URL. |
| Filename | Template; default `%filename%-%random-6%`. Supports `%filename%`, `%ext%`, `%random-N%` (1–64), `%uuid%`, `%date%`, `%year%`, `%month%`, `%day%`, `%timestamp%`. Names always end in the file's extension, once: `%filename%.%ext%` and `%filename%` both give `shot.png`, and `.tar.gz` stays together. A template without placeholders gets a random suffix so uploads never overwrite each other. Names are made URL-safe. |
| Upload with public-read ACL | Off by default. New AWS buckets disable ACLs and reject uploads that send one. |
| Use path-style requests | For services that need it. Buckets with dots in their name always use it. |

Add as many destinations as you like; the **Default** one is used by Cloud Share. Run **Test
Destination** on a destination to upload a small file, fetch it through the public URL, and delete it.

### AWS permissions and public access

The access key needs `s3:PutObject`, `s3:DeleteObject`, and `s3:ListBucket` (for Cloud Shared) on
the bucket. Links work when objects are publicly readable, typically through a bucket policy:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": "*",
    "Action": "s3:GetObject",
    "Resource": "arn:aws:s3:::files.example.com/*"
  }]
}
```

For a custom domain, name the bucket after the domain and point a CNAME at it, or put CloudFront
in front. Then set the Public URL to that domain.

## Usage

- **Cloud Share** uploads the selected files or images to the default destination, copies the
  link (one per line for several files), and shows the shared link as the result so you can keep
  acting on it. If it can't share (no destination yet, or the upload fails), Tuna stays open and
  says why.
- **Cloud Share to…** appears with more than one destination and asks where to upload.
- **Cloud Share to Shelf** and **Cloud Share to Shelf via…** do the same in the background and
  put the links on Shelf, so you can keep working while large files upload.
- **Cloud Shared** lists the bucket newest first, under the prefix's fixed folders, and filters as
  you type. With one destination it opens straight to the files. Listing stops after 5,000 files.
  Listings refresh when Tuna rescans the catalog or a destination changes. Browsing a listing
  older than 30 seconds shows it while the bucket is listed again, so files added elsewhere
  appear; a failed listing is retried when you browse it again. Shared files are URLs, so the usual Open and Copy actions
  apply; **Delete from Cloud** removes them after confirmation.

Folders are not uploaded. Nothing is uploaded or listed until you run an action or browse.
