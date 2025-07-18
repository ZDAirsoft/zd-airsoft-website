document.addEventListener("DOMContentLoaded", () => {
  console.log("Z&D Airsoft loaded successfully!");

  // Carousel Setup
  let currentIndex = 0;
  const slides = document.querySelectorAll(".carousel-slide");
  const caption = document.getElementById("carouselCaption");
  const playPauseBtn = document.getElementById("playPauseBtn");
  let playing = true;
  let interval;

  function showSlide(index) {
    slides.forEach((slide, i) => {
      slide.style.display = i === index ? "block" : "none";
    });
    caption.textContent = slides[index]?.alt || "";
  }

  function nextSlide() {
    currentIndex = (currentIndex + 1) % slides.length;
    showSlide(currentIndex);
  }

  function prevSlide() {
    currentIndex = (currentIndex - 1 + slides.length) % slides.length;
    showSlide(currentIndex);
  }

  function togglePlay() {
    if (playing) {
      clearInterval(interval);
      playPauseBtn.textContent = "▶️";
    } else {
      interval = setInterval(nextSlide, 3000);
      playPauseBtn.textContent = "⏸️";
    }
    playing = !playing;
  }

  if (slides.length > 0) {
    showSlide(currentIndex);
    interval = setInterval(nextSlide, 3000);
    slides.forEach(slide => slide.addEventListener("click", togglePlay));
    document.querySelector(".carousel-controls button:nth-child(1)").onclick = prevSlide;
    document.querySelector(".carousel-controls button:nth-child(2)").onclick = togglePlay;
    document.querySelector(".carousel-controls button:nth-child(3)").onclick = nextSlide;
  }

  // Hamburger Menu
  const menuToggle = document.querySelector(".menu-toggle");
  const navMenu = document.getElementById("navMenu");
  if (menuToggle && navMenu) {
    menuToggle.addEventListener("click", () => {
      navMenu.classList.toggle("active");
    });
    navMenu.querySelectorAll("a").forEach(link => {
      link.addEventListener("click", () => {
        navMenu.classList.remove("active");
      });
    });
  }
});
