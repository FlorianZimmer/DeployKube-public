package templates

import (
	"embed"
	"io/fs"
	"sort"
)

type FS interface {
	ListFiles(root string) ([]string, error)
	ReadFile(path string) ([]byte, error)
}

type EmbedFS struct {
	fs embed.FS
}

func (e EmbedFS) ListFiles(root string) ([]string, error) {
	var files []string
	if err := fs.WalkDir(e.fs, root, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			return nil
		}
		files = append(files, path)
		return nil
	}); err != nil {
		return nil, err
	}
	sort.Strings(files)
	return files, nil
}

func (e EmbedFS) ReadFile(path string) ([]byte, error) {
	return e.fs.ReadFile(path)
}
