// Add interactivity here if needed
console.log("Z&D Airsoft loaded successfully!");
let currentIndex = 0;
let slides = document.querySelectorAll('.carousel-slide');
let playing = true;
let interval = setInterval(nextSlide, 3000);

function showSlide(index) {
  slides.forEach((slide, i) => {
    slide.style.display = i === index ? 'block' : 'none';
  });

  // Update caption
  const caption = document.getElementById('carouselCaption');
  caption.textContent = slides[index].alt || '';
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
  const btn = document.getElementById('playPauseBtn');
  if (playing) {
    clearInterval(interval);
    btn.textContent = '▶️';
  } else {
    interval = setInterval(nextSlide, 3000);
    btn.textContent = '⏸️';
  }
  playing = !playing;
}

// 🔥 NEW: Click image to toggle play/pause
slides.forEach(slide => {
  slide.addEventListener('click', togglePlay);
});

showSlide(currentIndex);

function toggleMenu() {
  document.getElementById('navMenu').classList.toggle('open');
}

// Show/hide back to top button
window.onscroll = function () {
  const topBtn = document.getElementById("backToTop");
  if (document.body.scrollTop > 300 || document.documentElement.scrollTop > 300) {
    topBtn.style.display = "block";
  } else {
    topBtn.style.display = "none";
  }
};

// Scroll to top when clicked
document.getElementById("backToTop").addEventListener("click", function () {
  window.scrollTo({ top: 0, behavior: "smooth" });
});

// Facebook Button
function toggleFBPanel() {
  const panel = document.getElementById("fbFeedPanel");
  panel.classList.toggle("visible");
}

document.getElementById("fbToggle").addEventListener("click", toggleFBPanel);
