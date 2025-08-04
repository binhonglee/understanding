package main

import (
	"database/sql"
	"encoding/json"
	"log"
	"net/http"
	"time"

	_ "github.com/mattn/go-sqlite3"
)

type UnderstandingData struct {
	Referrer  string `json:"referrer"`
	UserAgent string `json:"user_agent"`
	DarkMode  *bool  `json:"dark_mode"`
	URL       string `json:"url"`
	Timestamp string `json:"timestamp"`
}

var db *sql.DB

func initDB() error {
	var err error
	db, err = sql.Open("sqlite3", "./understanding.db")
	if err != nil {
		return err
	}

	// Create table if it doesn't exist
	createTableSQL := `
	CREATE TABLE IF NOT EXISTS understanding_data (
		ip_address TEXT,
		referrer TEXT,
		user_agent TEXT,
		dark_mode BOOLEAN,
		url TEXT,
		timestamp DATETIME,
		created_at DATETIME DEFAULT CURRENT_TIMESTAMP
	);`

	_, err = db.Exec(createTableSQL)
	return err
}

func understandingHandler(w http.ResponseWriter, r *http.Request) {
	// Always return 200 OK regardless of errors
	defer func() {
		w.WriteHeader(http.StatusOK)
		w.Write([]byte("OK"))
	}()

	if r.Method != http.MethodPost {
		log.Printf("Invalid method: %s", r.Method)
		return
	}

	// Get IP address from X-Real-IP header, fallback to RemoteAddr
	ipAddress := r.Header.Get("X-Real-IP")
	if ipAddress == "" {
		ipAddress = r.RemoteAddr
	}

	// Parse JSON body
	var data UnderstandingData
	if err := json.NewDecoder(r.Body).Decode(&data); err != nil {
		log.Printf("Error parsing JSON: %v", err)
		return
	}

	// Parse timestamp
	var timestamp time.Time
	var err error
	if data.Timestamp != "" {
		timestamp, err = time.Parse(time.RFC3339, data.Timestamp)
		if err != nil {
			log.Printf("Error parsing timestamp: %v", err)
			timestamp = time.Now()
		}
	} else {
		timestamp = time.Now()
	}

	// Insert into database
	insertSQL := `
	INSERT INTO understanding_data (ip_address, referrer, user_agent, dark_mode, url, timestamp)
	VALUES (?, ?, ?, ?, ?, ?)`

	_, err = db.Exec(insertSQL, ipAddress, data.Referrer, data.UserAgent, data.DarkMode, data.URL, timestamp)
	if err != nil {
		log.Printf("Error inserting data: %v", err)
		return
	}

	log.Printf("Stored understanding data from IP: %s, URL: %s", ipAddress, data.URL)
}

func main() {
	// Initialize database
	if err := initDB(); err != nil {
		log.Fatal("Failed to initialize database:", err)
	}
	defer db.Close()

	// Set up routes
	http.HandleFunc("/", understandingHandler)

	// Start server
	log.Println("Server starting on :8088")
	log.Fatal(http.ListenAndServe(":8088", nil))
}
